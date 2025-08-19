#!/bin/bash
set -Eeuo pipefail

# ==== Config you may override via env or args ====
TGT_NS="${TGT_NS:-kafka}"
SECRET_NAME="${SECRET_NAME:-my-user}"           # name of secret on TARGET holding the password
KAFKA_USER="${KAFKA_USER:-my-user}"             # SASL/SCRAM username on SOURCE
SOURCE_BOOTSTRAP="${SOURCE_BOOTSTRAP:-External-IP:9092}"  # Azure external 9092
MM2_FILE="${MM2_FILE:-scram-final-mm2.yaml}"

# Default password (from your source cluster)
DEFAULT_PASSWORD="ek8zzNWzo1QzmPbn2kt4nIdoAQr3hQP2"
# PASSWORD precedence: $PASSWORD env var > arg1 > DEFAULT
PASSWORD="${PASSWORD:-${1:-$DEFAULT_PASSWORD}}"
PASSWORD="$(printf "%s" "$PASSWORD")"   # trim any accidental newlines

echo "[1] Creating/updating secret '${SECRET_NAME}' in namespace '${TGT_NS}'..."
kubectl create secret generic "${SECRET_NAME}" \
  --from-literal=password="${PASSWORD}" \
  -n "${TGT_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[2] Writing MirrorMaker2 CR to ${MM2_FILE}..."
cat > "${MM2_FILE}" <<EOF
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaMirrorMaker2
metadata:
  name: my-mm2
  namespace: ${TGT_NS}
spec:
  version: 4.0.0
  replicas: 1
  connectCluster: "target"

  clusters:
    - alias: "source"
      bootstrapServers: ${SOURCE_BOOTSTRAP}
      authentication:
        type: scram-sha-512
        username: ${KAFKA_USER}
        passwordSecret:
          secretName: ${SECRET_NAME}
          password: password

    - alias: "target"
      bootstrapServers: my-cluster-kafka-bootstrap.${TGT_NS}.svc.cluster.local:9092

  mirrors:
    - sourceCluster: "source"
      targetCluster: "target"
      topicsPattern: ".*"
      groupsPattern: ".*"

      # MirrorSourceConnector options
      sourceConnector:
        config:
          replication.policy.class: "org.apache.kafka.connect.mirror.IdentityReplicationPolicy"
          replication.factor: 1
          emit.heartbeats.enabled: true
          sync.group.offsets.enabled: true
          sync.topic.configs.enabled: true
          refresh.topics.interval.seconds: 30
          refresh.groups.interval.seconds: 30

      # Heartbeats connector options
      heartbeatConnector:
        config:
          heartbeats.topic.replication.factor: 1

      # Checkpoints connector options
      checkpointConnector:
        config:
          replication.policy.class: "org.apache.kafka.connect.mirror.IdentityReplicationPolicy"
          checkpoints.topic.replication.factor: 1
EOF

echo "[3] Applying MirrorMaker2 CR..."
kubectl apply -f "${MM2_FILE}" -n "${TGT_NS}"

echo "[4] Done. Watch pods and logs:"
echo "  kubectl get pods -n ${TGT_NS} -w"
echo "  kubectl logs deploy/my-mm2-mirrormaker2 -n ${TGT_NS} -f | egrep -i 'Submitting|connector|error|exception'"
