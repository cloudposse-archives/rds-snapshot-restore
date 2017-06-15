#!/usr/bin/env bash

set -e

CLUSTER=$1
SNAPSHOT_ID=$2

MASTER_PASSWORD=${MASTER_PASSWORD:-}

REGION=${REGION:-"us-west-2"}
SLEEP=${SLEEP:-10}

TMP_SUFFIX=${TMP_SUFFIX:-"-tmp"}
TO_DELETE_SUFFIX=${TO_DELETE_SUFFIX:-"-to-delete"}

CLUSTER_TMP="${CLUSTER}${TMP_SUFFIX}"
CLUSTER_TO_DELETE="${CLUSTER}${TO_DELETE_SUFFIX}"

DRY_RUN=${DRY_RUN:-false}

###======================Functions===========================================####

instance_exists() {
  local INSTANCE=$1

  local TMP_INSTANCE_EXISTS=$( aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}" | \
                          jq -cr '.DBInstances | length' )
  if [ "$TMP_INSTANCE_EXISTS" == "0" ]
  then
    echo false
  else
    echo true
  fi
}

wait_instance_state() {
  local INSTANCE=$1
  local STATE=$2
  while true; do
    local INSTANCE_STATUS=$(aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}" | \
      jq -cr '.DBInstances[].DBInstanceStatus')

    if [[ $DRY_RUN == "true" ||  "$INSTANCE_STATUS" == "${STATE}" ]]; then
      break;
    fi
    echo "Instance ${INSTANCE} is ${INSTANCE_STATUS}"
    sleep 1
  done
}

wait_instance_not_exists() {
  local INSTANCE=$1
  while true; do
    if [[ $DRY_RUN == "true" ||  $(instance_exists "$INSTANCE") == "false" ]]; then
      break;
    fi
    echo "Instance ${INSTANCE} is ${INSTANCE_STATUS}"
    sleep 1
  done
}

rename_instance() {
  local INSTANCE_NAME=$1
  local NEW_INSTANCE_NAME=$2

  if [[ $(instance_exists "$INSTANCE_NAME") == "true" ]]
  then
    [ $DRY_RUN == "true" ] ||  aws --region $REGION rds modify-db-instance \
                                    --db-instance-identifier "${INSTANCE_NAME}" \
                                    --new-db-instance-identifier "${NEW_INSTANCE_NAME}" \
                                    --apply-immediately
    echo "Rename instance ${INSTANCE_NAME} to ${NEW_INSTANCE_NAME}"

    wait_instance_state "${INSTANCE_NAME}" "renaming"
    wait_instance_state "${NEW_INSTANCE_NAME}" "available"
  else
      echo "WARNING: Instance ${INSTANCE_NAME} not exists"
  fi
}

delete_instance() {
  local INSTANCE_NAME=$1

  if [[ $(instance_exists "$INSTANCE_NAME") == "true" ]]
  then
    [ $DRY_RUN == "true" ] ||  aws --region $REGION rds delete-db-instance \
                                    --db-instance-identifier "${INSTANCE_NAME}" \
    echo "Delete instance ${INSTANCE_NAME}"

    wait_instance_state "${INSTANCE_NAME}" "deleting"
  else
      echo "WARNING: Instance ${INSTANCE_NAME} not exists"
  fi
}


wait_cluster_state() {
  local CLUSTER=$1
  local STATE=$2
  while true; do
    local CLUSTER_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER" | \
      jq -cr '.DBClusters[0].Status')

    if [[ $DRY_RUN == "true" ||  "$CLUSTER_STATUS" == "${STATE}" ]]; then
      break;
    fi

    echo "Cluster ${CLUSTER} is ${CLUSTER_STATUS}"
    sleep 1
  done
}

wait_all_instances_in_cluster_state() {
  local CLUSTER=$1
  local STATE=$2
  while true; do
    local COUNT_NOT_READY_INSTANCES=$(aws --region $REGION rds describe-db-instances --filter "Name=db-cluster-id,Values=${CLUSTER}" | \
      jq -cr ".DBInstances | map( select( .DBInstanceStatus != \"${STATE}\" )) | length")

    if [[ $DRY_RUN == "true" || "$COUNT_NOT_READY_INSTANCES" == "0" ]]; then
      echo "All instances in cluster ${CLUSTER} are ${STATE}"
      break;
    fi

    echo "$COUNT_NOT_READY_INSTANCES instances in ${CLUSTER} is not ${STATE}"
    sleep ${SLEEP}
  done
}


rename_cluster() {
  local CLUSTER_NAME=$1
  local NEW_CLUSTER_NAME=$2

  echo "Rename cluster ${CLUSTER_NAME} to ${NEW_CLUSTER_NAME}"

  [ $DRY_RUN == "true" ] || aws --region $REGION rds modify-db-cluster \
                                --db-cluster-identifier "${CLUSTER_NAME}" \
                                --new-db-cluster-identifier "${NEW_CLUSTER_NAME}" \
                                --apply-immediately

  wait_cluster_state "$CLUSTER_NAME" "renaming"
  wait_cluster_state "$NEW_CLUSTER_NAME" "available"
}

cluster_change_master_password() {
  local CLUSTER=$1
  local PASSWORD=$2

  [ $DRY_RUN == "true" ] || aws --region $REGION rds modify-db-cluster \
                                --db-cluster-identifier "${CLUSTER}" \
                                --master-user-password "${PASSWORD}" \
                                --apply-immediately
  echo "Reset master password for cluster ${CLUSTER}"
  sleep ${SLEEP}
  wait_cluster_state "$CLUSTER" "available"
}

copy_cluster() {
  local SOURCE=$1
  local TARGET=$2
  local SNAPSHOT=$3

  local CLUSTER_MAP_QUERY=$( cat <<EOF
    .DBClusters[0] |
      {
        AvailabilityZones: .AvailabilityZones,
        DBClusterIdentifier: "\(.DBClusterIdentifier)-tmp",
        SnapshotIdentifier: "${SNAPSHOT}",
        Engine: .Engine,
        EngineVersion: .EngineVersion,
        Port: .Port,
        DBSubnetGroupName: .DBSubnetGroup,
        DatabaseName: .DatabaseName,
        VpcSecurityGroupIds: [.VpcSecurityGroups[].VpcSecurityGroupId],
        EnableIAMDatabaseAuthentication: .IAMDatabaseAuthenticationEnabled
      }
EOF
  )

  local CLUSTER_JSON=$( aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$SOURCE" | jq -cM "$CLUSTER_MAP_QUERY" )

  if [ "$CLUSTER_JSON" == "" ]
  then
   echo "ERROR: Cluster ${SOURCE} not exists";
   exit 1;
  fi

  local TMP_CLUSTER_EXISTS=$( aws --region $REGION rds describe-db-clusters --filter "Name=db-cluster-id,Values=${TARGET}" | \
                        jq -cr '.DBClusters | length' )

  if [ $TMP_CLUSTER_EXISTS -eq 0 ]
  then
    [ $DRY_RUN == "true" ] || aws --region $REGION rds restore-db-cluster-from-snapshot --cli-input-json "$CLUSTER_JSON"
    echo "Copying cluster ${SOURCE} to ${TARGET}......In process"
  else
    echo "WARNING: Cluster ${TARGET} exists"
  fi
}

copy_instance() {
  local SOURCE=$1
  local TARGET=$2
  local CLUSTER=$3

  local INSTANCE_MAP_QUERY=$( cat <<EOF
    .DBInstances[0] |
      {
        DBInstanceIdentifier: "${TARGET}",
        DBInstanceClass: .DBInstanceClass,
        Engine: .Engine,
        DBSecurityGroups: .DBSecurityGroups,
        AvailabilityZone: .AvailabilityZone,
        DBSubnetGroupName: .DBSubnetGroup.DBSubnetGroupName,
        PreferredMaintenanceWindow: .PreferredMaintenanceWindow,
        DBParameterGroupName: .DBParameterGroups[0].DBParameterGroupName,
        MultiAZ: .MultiAZ,
        EngineVersion: .EngineVersion,
        AutoMinorVersionUpgrade: .AutoMinorVersionUpgrade,
        LicenseModel: .LicenseModel,
        OptionGroupName: .OptionGroupMemberships[0].OptionGroupName,
        PubliclyAccessible: .PubliclyAccessible,
        DBClusterIdentifier: "${CLUSTER}",
        StorageType: .StorageType,
        StorageEncrypted: .StorageEncrypted,
        CopyTagsToSnapshot: .CopyTagsToSnapshot,
        MonitoringInterval: .MonitoringInterval,
        PromotionTier: .PromotionTier,
      }
EOF
  )

  if [[ $(instance_exists "$TARGET") == "false" ]];
  then
    local INSTANCE_JSON=$( aws --region $REGION rds describe-db-instances --db-instance-identifier "$SOURCE" |
                  jq -cM "$INSTANCE_MAP_QUERY" )

    [ $DRY_RUN == "true" ] || aws --region $REGION rds create-db-instance --cli-input-json "$INSTANCE_JSON"
    echo "Copying instance $SOURCE to ${TARGET} ......In process"
  else
    echo "WARNING: Instance ${TARGET} exists"
  fi
}


####==================== Restoring cluster =================================#####

copy_cluster "$CLUSTER" "${CLUSTER_TMP}" "${SNAPSHOT_ID}"

readarray -t INSTANCES < <( aws --region $REGION rds describe-db-instances --filter "Name=db-cluster-id,Values=${CLUSTER}" | \
                              jq -cr '.DBInstances[].DBInstanceIdentifier')

for INSTANCE in "${INSTANCES[@]}"; do
  copy_instance "$INSTANCE" "${INSTANCE}${TMP_SUFFIX}" "${CLUSTER_TMP}"
done
wait_cluster_state "$CLUSTER_TMP" "available"
wait_all_instances_in_cluster_state "${CLUSTER_TMP}" "available"
cluster_change_master_password "${CLUSTER_TMP}" "${MASTER_PASSWORD}"

rename_cluster "${CLUSTER}" "${CLUSTER_TO_DELETE}"
rename_cluster "${CLUSTER_TMP}" "${CLUSTER}"

####==================== Rename instances =================================#####

for INSTANCE in "${INSTANCES[@]}"; do
  rename_instance "${INSTANCE}" "${INSTANCE}${TO_DELETE_SUFFIX}"
done

for INSTANCE in "${INSTANCES[@]}"; do
  rename_instance "${INSTANCE}${TMP_SUFFIX}" "${INSTANCE}"
done

###================== Delete instances ====================================####

for INSTANCE in "${INSTANCES[@]}"; do
  delete_instance "${INSTANCE}${TO_DELETE_SUFFIX}"
done

for INSTANCE in "${INSTANCES[@]}"; do
  wait_instance_not_exists "${INSTANCE}${TO_DELETE_SUFFIX}"
done


echo "......................................................... Done"
