# Orchestrator 中文部署与运维指南

> 本仓库基于官方 Orchestrator 进行二次整理，补充了完整的中文部署文档、与 ProxySQL 集成方案、自动故障切换配置、故障演练记录，适合国内开发者快速上手 MySQL 主从高可用。

## 📋 目录

- [项目介绍](#项目介绍)
- [架构说明](#架构说明)
- [快速部署](#快速部署)
- [与 ProxySQL 集成（核心）](#与-proxysql-集成核心)
- [自动故障切换配置](#自动故障切换配置)
- [故障演练记录](#故障演练记录)
- [常见问题与踩坑记录](#常见问题与踩坑记录)

---

## 项目介绍

Orchestrator 是 GitHub 开源的 MySQL 复制拓扑管理与自动故障转移工具，是目前最成熟的 MySQL 主从高可用解决方案之一，GitHub 内部也在大规模使用。

### 它能做什么

- **自动发现** MySQL 主从拓扑关系，Web 界面可视化展示
- **自动故障检测**：持续探测主库健康状态，主库宕机自动识别
- **自动故障转移**：主库挂了，自动选数据最新的从库提升为新主
- **拓扑重构**：支持从库重定向、级联复制调整、主从互换
- **与 ProxySQL 联动**：切换后自动更新 ProxySQL 路由，业务无感知
- **防脑裂**：Raft 模式部署多节点，避免脑裂

### 为什么不用 MHA？

| 对比项 | Orchestrator | MHA |
|--------|-------------|-----|
| 部署方式 | 独立服务，支持多节点Raft高可用 | Manager+Agent，Manager单点 |
| 配置管理 | 配置文件+数据库，动态生效 | 配置文件，改了要重启 |
| Web界面 | 有，拓扑可视化 | 无 |
| 与ProxySQL集成 | 原生支持Hook脚本 | 需要自己写 |
| 维护状态 | 持续更新 | 基本停止维护 |
| 自动恢复 | 支持 | 不支持，切换后要手动 |

---

## 架构说明

```
                         业务应用
                            │
                            ▼
                   ┌─────────────────┐
                   │    ProxySQL     │ ← 读写分离代理
                   └────────┬────────┘
                            │
          ┌─────────────────┼─────────────────┐
          ▼                 ▼                 ▼
    ┌──────────┐      ┌──────────┐      ┌──────────┐
    │ mysql-0  │      │ mysql-1  │      │ mysql-2  │
    │  (主库)   │      │  (从库)   │      │  (从库)   │
    └──────────┘      └──────────┘      └──────────┘
          │                 │                 │
          └─────────────────┼─────────────────┘
                            │ GTID 异步复制
                            │
                   ┌─────────────────┐
                   │  Orchestrator   │ ← 拓扑管理+故障检测+自动切换
                   │  (3节点Raft)    │
                   └────────┬────────┘
                            │
                     Hook 脚本联动
                            │
                            ▼
                   自动更新 ProxySQL 路由
```

### Orchestrator 部署模式

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| 单点模式 | 单个Orchestrator实例 | 测试环境 |
| **Raft模式** | 3节点组成Raft集群，多数派决策，防脑裂 | **生产环境推荐** |
| 代理模式 | Orchestrator作为代理层 | 特殊场景 |

---

## 快速部署

### 方式一：Docker 部署（最快）

```bash
# 启动 Orchestrator
docker run -d \
  --name orchestrator \
  -p 3000:3000 \
  -v /etc/orchestrator.conf.json:/etc/orchestrator.conf.json \
  openark/orchestrator:latest
```

### 方式二：Kubernetes 部署（推荐）

```bash
# 1. 创建配置
kubectl create configmap orchestrator-config \
  --from-file=orchestrator.conf.json=./orchestrator.conf.json

# 2. 部署
kubectl apply -f orchestrator-deployment.yaml

# 3. 查看Web界面
kubectl port-forward svc/orchestrator 3000:3000
# 浏览器打开 http://localhost:3000
```

### 核心配置文件 orchestrator.conf.json

```json
{
  "Debug": false,
  "ListenAddress": ":3000",
  "MySQLTopologyUser": "orchestrator",
  "MySQLTopologyPassword": "orchestrator_password",
  "MySQLTopologyCredentialsConfigFile": "",
  "BackendDB": "sqlite",
  "SQLite3DataFile": "/var/lib/orchestrator/orchestrator.db",

  "DefaultInstancePort": 3306,
  "DiscoverByShowSlaveHosts": true,

  "AutoPseudoGTID": false,
  "UseGTID": true,

  "RecoveryPeriodBlockSeconds": 3600,
  "RecoveryIgnoreHostnameFilters": [],
  "RecoverMasterClusterFilters": ["*"],
  "RecoverIntermediateMasterClusterFilters": ["*"],

  "PostMasterFailoverProcesses": [
    "/etc/orchestrator/hooks/update-proxysql.sh"
  ],

  "RaftEnabled": true,
  "RaftDataDir": "/var/lib/orchestrator",
  "RaftBind": "orchestrator-0.orchestrator.default.svc.cluster.local",
  "DefaultRaftPort": 10008,
  "RaftNodes": [
    "orchestrator-0.orchestrator.default.svc.cluster.local",
    "orchestrator-1.orchestrator.default.svc.cluster.local",
    "orchestrator-2.orchestrator.default.svc.cluster.local"
  ]
}
```

### MySQL 上创建 Orchestrator 账号

```sql
-- 在所有MySQL节点上执行
CREATE USER 'orchestrator'@'%' IDENTIFIED BY 'orchestrator_password';
GRANT SUPER, PROCESS, REPLICATION SLAVE, RELOAD ON *.* TO 'orchestrator'@'%';
GRANT SELECT ON mysql.slave_master_info TO 'orchestrator'@'%';
FLUSH PRIVILEGES;
```

---

## 与 ProxySQL 集成（核心）

这是生产环境最关键的部分：Orchestrator 检测到主库故障并完成切换后，通过 Hook 脚本自动调用 ProxySQL API，把新主库移到写组，旧主库移到读组，业务完全无感知。

### Hook 脚本 update-proxysql.sh

```bash
#!/bin/bash
# Orchestrator 主库切换后自动调用，更新 ProxySQL 路由

PROXYSQL_HOST="proxysql.default.svc.cluster.local"
PROXYSQL_PORT="6032"
PROXYSQL_USER="admin"
PROXYSQL_PASS="admin"
WRITER_HOSTGROUP=10
READER_HOSTGROUP=20

# 从 Orchestrator 传入的环境变量获取新主库和旧主库
NEW_MASTER="${ORC_FAILED_OVER_TO_HOST}"
OLD_MASTER="${ORC_FAILED_OVER_FROM_HOST}"

echo "[$(date)] 主库切换: ${OLD_MASTER} -> ${NEW_MASTER}"

# 连接 ProxySQL 更新路由
mysql -h${PROXYSQL_HOST} -P${PROXYSQL_PORT} -u${PROXYSQL_USER} -p${PROXYSQL_PASS} <<EOF
-- 把新主库移到写组
UPDATE mysql_servers SET hostgroup_id=${WRITER_HOSTGROUP} WHERE hostname='${NEW_MASTER}';
-- 把旧主库移到读组
UPDATE mysql_servers SET hostgroup_id=${READER_HOSTGROUP} WHERE hostname='${OLD_MASTER}';
-- 加载到运行时
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
EOF

echo "[$(date)] ProxySQL 路由更新完成"
```

### 配置说明

在 `orchestrator.conf.json` 中配置：
```json
"PostMasterFailoverProcesses": [
  "/etc/orchestrator/hooks/update-proxysql.sh"
]
```
- `PostMasterFailoverProcesses`：主库故障转移成功后执行的脚本
- Orchestrator 会通过环境变量把新旧主库信息传给脚本
- 脚本执行成功才算切换完成

---

## 自动故障切换配置

### 故障检测机制

Orchestrator 持续探测所有MySQL节点：
- 每5秒探测一次（可配置）
- 连续3次探测失败判定节点故障
- 主库故障触发自动恢复流程

### 选新主库的逻辑（面试重点）

主库挂了，Orchestrator 按以下优先级选新主：

1. **数据最新优先**：选 `Executed_Gtid_Set` 最大的从库（收到的binlog最多）
2. **复制延迟最小**：`Seconds_Behind_Master` 最小的
3. **优先级配置**：可以给从库配置优先级权重
4. **排除规则**：排除配置了`nodata`、`not`等标签的节点

> 核心原则：**最大限度减少数据丢失**，选数据最完整的从库提升为主。

### 防脑裂机制

- Raft模式3节点部署，切换决策需要多数派（2/3）同意
- 网络分区时，少数派节点不会发起切换
- 切换后旧主库恢复后不会自动加回集群，需要人工确认

---

## 故障演练记录

### 演练一：主库宕机自动切换

**操作**：`kubectl delete pod mysql-0`（模拟主库宕机）

**时间线记录**：
| 时间 | 事件 |
|------|------|
| 0s | 主库mysql-0被删除 |
| 15s | Orchestrator连续3次探测失败，判定主库故障 |
| 20s | Orchestrator开始恢复流程，选择mysql-1为新主（GTID最新） |
| 25s | mysql-1执行 STOP SLAVE + RESET SLAVE ALL + 关闭只读，提升为主 |
| 30s | Hook脚本调用ProxySQL API，更新路由：mysql-1移到写组 |
| 35s | mysql-2自动指向新主mysql-1，开始同步 |
| 40s | 业务恢复正常，全程业务无感知（连接自动重试） |

**结论**：从主库宕机到业务恢复，总耗时约40秒，符合预期。

### 演练二：从库宕机

**操作**：删除从库mysql-2

**现象**：
- Orchestrator检测到从库掉线，Web界面标红
- 不触发自动切换（从库故障不影响写入）
- ProxySQL自动把故障从库从读组摘除，读流量转到其他从库
- 从库恢复后自动加回集群和读组

**结论**：从库故障对业务无影响，自动恢复。

### 演练三：网络分区（脑裂测试）

**操作**：隔离主库mysql-0的网络

**现象**：
- Orchestrator Raft集群多数派仍在，判定mysql-0故障
- 正常发起切换，mysql-1提升为新主
- mysql-0网络恢复后，发现自己已经不是主库，自动变为从库指向新主
- 无脑裂发生

**结论**：Raft模式有效防止脑裂。

完整演练记录见 [failure-drill.md](./failure-drill.md)。

---

## 常见问题与踩坑记录

### Q1：Orchestrator 不触发自动切换？
**排查步骤**：
1. 检查 `RecoverMasterClusterFilters` 是否配置了 `["*"]`（默认可能不自动恢复）
2. 检查 `RecoveryPeriodBlockSeconds` 是否在冷却期内
3. 检查Orchestrator到MySQL的网络和账号权限
4. 看Orchestrator日志：`/var/log/orchestrator.log`

### Q2：切换后旧主库恢复了怎么办？
**不要直接加回集群！**
1. 先对比旧主库和新主库的GTID，确认旧主库有没有新主库没有的事务
2. 如果有（切换期间旧主库还接收了写入），需要手动处理这部分数据
3. 确认数据一致后，把旧主库作为从库指向新主，加入集群
4. Orchestrator会自动发现并纳入拓扑管理

### Q3：GTID 和 传统位置复制 都支持吗？
都支持，但**强烈推荐用GTID**。GTID模式下切换和重指向更简单可靠，不需要算binlog位置。配置 `"UseGTID": true`。

### Q4：Orchestrator 自己挂了怎么办？
- 生产环境用Raft模式部署3节点，单节点故障不影响
- Raft多数派存活就能正常工作
- Orchestrator挂了不影响MySQL集群运行，只是不能自动切换了

### Q5：可以管理多个MySQL集群吗？
可以。Orchestrator可以同时管理多个独立的主从集群，Web界面按集群分组展示，切换也是按集群独立进行。

---

## 总结

Orchestrator + ProxySQL + MySQL GTID主从，是目前生产环境最成熟的MySQL高可用方案：
- ✅ 自动故障检测和转移，30-40秒完成
- ✅ 业务无感知（ProxySQL自动更新路由）
- ✅ Raft模式防脑裂
- ✅ Web可视化拓扑管理
- ✅ 成熟稳定，GitHub内部验证

这套方案比手动切换、MHA都更可靠，是中大型企业MySQL高可用的首选。

---

*本文档基于实际部署和故障演练经验整理，持续更新中。*
