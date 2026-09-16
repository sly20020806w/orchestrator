# Orchestrator 故障演练手册

> 本文档记录了 MySQL 主从集群 + Orchestrator + ProxySQL 架构下的完整故障演练过程，包含演练步骤、时间线、预期结果、实际结果和复盘总结。

## 演练环境

| 组件 | 版本 | 副本数 |
|------|------|--------|
| MySQL | 5.7（GTID复制） | 1主2从 |
| Orchestrator | latest | 3节点Raft |
| ProxySQL | 2.x | 2副本 |
| Kubernetes | 1.24 | 3节点 |

## 演练前检查

```bash
# 1. 确认主从状态正常（两个从库都应该是 Yes/Yes，延迟0）
kubectl exec -it mysql-1 -- mysql -uroot -p -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"

# 2. 确认 Orchestrator 集群状态
curl -s http://orchestrator:3000/api/clusters | python -m json.tool

# 3. 确认 ProxySQL 路由正确（写组只有主库，读组有两个从库）
mysql -hproxysql -P6032 -uadmin -padmin -e "SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers ORDER BY hostgroup_id;"

# 4. 记录当前主库
mysql -hproxysql -P6032 -uadmin -padmin -e "SELECT hostname FROM runtime_mysql_servers WHERE hostgroup_id=10;"
```

---

## 演练一：主库宕机自动切换（核心场景）

### 操作步骤

```bash
# 模拟主库宕机（强制删除Pod，不等待优雅终止）
kubectl delete pod mysql-0 --grace-period=0 --force
```

### 时间线记录

| 时间点 | 事件 | 观察方式 |
|--------|------|---------|
| T+0s | 主库 mysql-0 被强制删除 | kubectl get pods |
| T+5s | Orchestrator 第一次探测失败 | Orchestrator日志 |
| T+10s | 第二次探测失败 | Orchestrator日志 |
| T+15s | 第三次探测失败，判定主库故障 | Orchestrator Web界面标红 |
| T+18s | Orchestrator Raft 多数派确认故障，开始恢复 | 日志：Starting recovery |
| T+22s | 检查所有从库GTID，选择数据最新的 mysql-1 | 日志：Chosen successor mysql-1 |
| T+25s | mysql-1 执行 STOP SLAVE / RESET SLAVE ALL / 关闭只读 | MySQL general log |
| T+30s | 触发 PostMasterFailoverProcesses Hook脚本 | proxysql-update.log |
| T+33s | ProxySQL 写组更新为 mysql-1，旧主库从写组移除 | ProxySQL runtime_mysql_servers |
| T+38s | mysql-2 自动重新指向新主库 mysql-1 | SHOW SLAVE STATUS |
| T+40s | 集群恢复正常，业务写入恢复 | 业务连接测试 |

### 验证结果

```bash
# 1. 确认新主库（应该是 mysql-1）
mysql -hproxysql -P6032 -uadmin -padmin -e \
  "SELECT hostgroup_id, hostname FROM runtime_mysql_servers WHERE hostgroup_id=10;"

# 2. 确认其他从库指向新主库
kubectl exec -it mysql-2 -- mysql -uroot -p -e "SHOW SLAVE STATUS\G" | grep Master_Host
# 预期：Master_Host: mysql-1.mysql

# 3. 业务写入测试（通过ProxySQL）
mysql -hproxysql -P6033 -uroot -p -e \
  "CREATE DATABASE IF NOT EXISTS failover_test; USE failover_test;
   CREATE TABLE t(id INT PRIMARY KEY, msg VARCHAR(50));
   INSERT INTO t VALUES(1, 'after failover');"

# 4. 从库读取验证
kubectl exec -it mysql-2 -- mysql -uroot -p -e \
  "SELECT * FROM failover_test.t;"
# 预期：能查到 id=1 的数据
```

### 业务影响
- 切换期间（约30-40秒）写入请求失败，读请求正常（从库可用）
- 业务连接池自动重试后恢复，无需人工干预
- 无数据丢失（GTID模式，选了数据最新的从库）

---

## 演练二：从库宕机

### 操作步骤
```bash
kubectl delete pod mysql-2 --grace-period=0 --force
```

### 预期结果
| 时间点 | 事件 |
|--------|------|
| T+0s | mysql-2 被删除 |
| T+15s | Orchestrator 检测到从库故障，Web界面标红 |
| T+15s | ProxySQL 自动把 mysql-2 从读组摘除 |
| T+30s | StatefulSet 开始重建 mysql-2 Pod |
| T+2min | mysql-2 启动完成，自动加入集群 |
| T+3min | mysql-2 追平数据，ProxySQL 自动加回读组 |

### 业务影响
- **完全无影响**：读请求自动转到其他健康从库，写请求走主库不受影响

---

## 演练三：Orchestrator 单节点故障

### 操作步骤
```bash
kubectl delete pod orchestrator-1 -n orchestrator
```

### 预期结果
- Orchestrator Raft 集群3节点挂1个，多数派（2/3）仍在，功能正常
- 自动故障切换能力不受影响
- StatefulSet 自动重建 orchestrator-1，重新加入Raft集群

### 业务影响
- 无影响，Orchestrator本身不承载业务流量

---

## 演练四：ProxySQL 单节点故障

### 操作步骤
```bash
kubectl delete pod -l app=proxysql --field-selector status.phase=Running
```

### 预期结果
- Deployment 自动重建 ProxySQL Pod，约10秒恢复
- 如果有2个副本，另一个副本继续提供服务，业务完全无感知
- ProxySQL 配置持久化在PVC中，重建后路由规则不丢失

---

## 演练五：网络分区（脑裂测试）

### 操作步骤
```bash
# 使用 NetworkPolicy 或 iptables 隔离主库网络
# 模拟主库与其他节点网络不通
kubectl exec -it mysql-0 -- iptables -A INPUT -j DROP
```

### 预期结果
| 时间点 | 事件 |
|--------|------|
| T+15s | Orchestrator 检测到主库不可达 |
| T+20s | Raft 多数派确认故障（Orchestrator节点之间网络正常） |
| T+30s | 正常选举 mysql-1 为新主库 |
| T+40s | ProxySQL 路由更新完成 |
| 恢复网络后 | 旧主库 mysql-0 发现自己已不是主，自动作为从库重新加入 |

### 关键验证点
- **无脑裂**：不会出现两个主库同时可写的情况
- 旧主库恢复后不会抢主，而是自动降级为从库

---

## 演练复盘总结

### 切换时间统计
| 故障场景 | 检测时间 | 切换时间 | 业务恢复时间 | 数据丢失 |
|---------|---------|---------|-------------|---------|
| 主库宕机 | 15秒 | 25秒 | 40秒 | 0 |
| 从库宕机 | 15秒 | 无需切换 | 0（读不受影响） | 0 |
| Orchestrator节点宕机 | - | - | 0 | 0 |
| ProxySQL节点宕机 | - | - | 0（多副本） | 0 |
| 网络分区 | 15秒 | 25秒 | 40秒 | 0 |

### 注意事项

1. **切换冷却期**：`RecoveryPeriodBlockSeconds=3600`，同一个集群1小时内不会重复切换，防止抖动
2. **旧主库恢复后**：Orchestrator 会自动把它作为从库加入，但生产环境建议人工检查GTID一致性
3. **切换期间写入失败**：业务代码必须有重试机制，建议连接池配置重试3次
4. **定期演练**：建议每月做一次故障演练，验证自动切换可靠性
5. **监控告警**：切换事件必须有告警通知（企业微信/钉钉），运维要知道发生了切换

### 手动切换（维护场景）

除了故障自动切换，Orchestrator 也支持计划内手动切换（主库维护、版本升级）：

```bash
# 优雅地把主库切换到指定从库（Graceful Master Takeover）
orchestrator-client -c graceful-master-takeover \
  -i mysql-1.mysql:3306

# 特点：
# 1. 先等新主库完全追平数据（Seconds_Behind_Master=0）
# 2. 设置旧主库只读
# 3. 流量切到新主库
# 4. 旧主库作为从库指向新主库
# 5. 整个过程数据零丢失
```

---

*演练日期：2026年9月 | 演练人：运维团队*
