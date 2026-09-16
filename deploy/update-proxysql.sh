#!/bin/bash
# =============================================================================
# Orchestrator 主库故障切换后自动更新 ProxySQL 路由
# =============================================================================
# 触发时机：Orchestrator 完成主库故障转移后（PostMasterFailoverProcesses）
# 传入环境变量：
#   ORC_FAILED_OVER_FROM_HOST  - 旧主库主机名
#   ORC_FAILED_OVER_TO_HOST    - 新主库主机名
#   ORC_CLUSTER_NAME           - 集群名称
# =============================================================================

set -e

# ---------- 配置区（按实际环境修改） ----------
PROXYSQL_HOST="${PROXYSQL_HOST:-proxysql.default.svc.cluster.local}"
PROXYSQL_PORT="${PROXYSQL_PORT:-6032}"
PROXYSQL_USER="${PROXYSQL_USER:-admin}"
PROXYSQL_PASS="${PROXYSQL_PASS:-admin}"
WRITER_HOSTGROUP="${WRITER_HOSTGROUP:-10}"
READER_HOSTGROUP="${READER_HOSTGROUP:-20}"
LOG_FILE="/var/log/orchestrator/proxysql-update.log"
# ----------------------------------------------

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 从 Orchestrator 环境变量获取新旧主库
OLD_MASTER="${ORC_FAILED_OVER_FROM_HOST:-}"
NEW_MASTER="${ORC_FAILED_OVER_TO_HOST:-}"
CLUSTER="${ORC_CLUSTER_NAME:-unknown}"

log "========== 开始更新 ProxySQL 路由 =========="
log "集群: ${CLUSTER}"
log "旧主库: ${OLD_MASTER}"
log "新主库: ${NEW_MASTER}"

# 参数校验
if [ -z "$NEW_MASTER" ]; then
    log "错误：未获取到新主库主机名，退出"
    exit 1
fi

# 等待新主库可写（切换后可能需要几秒稳定）
log "等待新主库 ${NEW_MASTER} 可写..."
RETRY=0
MAX_RETRY=12
while [ $RETRY -lt $MAX_RETRY ]; do
    READ_ONLY=$(mysql -h"${NEW_MASTER}" -P3306 -uorchestrator -porchestrator_password \
        -N -e "SELECT @@global.read_only;" 2>/dev/null || echo "1")
    if [ "$READ_ONLY" = "0" ]; then
        log "新主库已可写"
        break
    fi
    RETRY=$((RETRY + 1))
    log "新主库仍为只读，等待5秒... (${RETRY}/${MAX_RETRY})"
    sleep 5
done

if [ $RETRY -eq $MAX_RETRY ]; then
    log "警告：等待新主库可写超时，继续更新 ProxySQL"
fi

# 更新 ProxySQL 路由
log "连接 ProxySQL ${PROXYSQL_HOST}:${PROXYSQL_PORT} 更新路由..."

mysql -h"${PROXYSQL_HOST}" -P"${PROXYSQL_PORT}" -u"${PROXYSQL_USER}" -p"${PROXYSQL_PASS}" 2>/dev/null <<EOF
-- 查看当前路由
SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers;

-- 把新主库移到写组
UPDATE mysql_servers
SET hostgroup_id = ${WRITER_HOSTGROUP}, status = 'ONLINE'
WHERE hostname = '${NEW_MASTER}';

-- 把旧主库移到读组（如果旧主库还存在）
UPDATE mysql_servers
SET hostgroup_id = ${READER_HOSTGROUP}
WHERE hostname = '${OLD_MASTER}';

-- 如果旧主库已经不存在，清理写组里的旧记录
DELETE FROM mysql_servers
WHERE hostgroup_id = ${WRITER_HOSTGROUP}
  AND hostname != '${NEW_MASTER}';

-- 加载到运行时并持久化
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;

-- 确认更新结果
SELECT hostgroup_id, hostname, status FROM runtime_mysql_servers;
EOF

if [ $? -eq 0 ]; then
    log "ProxySQL 路由更新成功：写组 -> ${NEW_MASTER}"
else
    log "错误：ProxySQL 路由更新失败，请人工检查！"
    exit 1
fi

log "========== ProxySQL 路由更新完成 =========="
exit 0
