#!/usr/bin/env bash

set -e

CLUSTER=$1
SNAPSHOT_ID=$2

MASTER_PASSWORD=$(MASTER_PASSWORD:-)

REGION=$(REGION:-"us-west-2")

SLEEP=$(SLEEP:-10)

TMP_SUFFIX=$(TMP_SUFFIX:-"-tmp")
TO_DELETE_SUFFIX=$(TO_DELETE_SUFFIX:-"-to-delete")

CLUSTER_TMP="${CLUSTER}${TMP_SUFFIX}"
CLUSTER_TO_DELETE="${CLUSTER}${TO_DELETE_SUFFIX}"

DRY_RUN=$(DRY_RUN:-false)

CLUSTER_MAP_QUERY=$( cat <<EOF
  .DBClusters[0] |
    {
      AvailabilityZones: .AvailabilityZones,
      DBClusterIdentifier: "\(.DBClusterIdentifier)-tmp",
      SnapshotIdentifier: "${SNAPSHOT_ID}",
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

INSTANCE_MAP_QUERY=$( cat <<EOF
  .DBInstances[0] |
    {
      DBInstanceIdentifier: "\(.DBInstanceIdentifier)${TMP_SUFFIX}",
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
      DBClusterIdentifier: "${CLUSTER_TMP}",
      StorageType: .StorageType,
      StorageEncrypted: .StorageEncrypted,
      CopyTagsToSnapshot: .CopyTagsToSnapshot,
      MonitoringInterval: .MonitoringInterval,
      PromotionTier: .PromotionTier,
    }
EOF
)

####==================== Restoring cluster =================================#####

CLUSTER_JSON=$( aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER" | jq -cM "$CLUSTER_MAP_QUERY" )

if [ "$CLUSTER_JSON" == "" ]
then
 echo "ERROR: Cluster ${CLUSTER} not exists";
 exit 1;
fi

TMP_CLUSTER_EXISTS=$( aws --region $REGION rds describe-db-clusters --filter "Name=db-cluster-id,Values=${CLUSTER_TMP}" | \
                      jq -cr '.DBClusters | length' )

if [ $TMP_CLUSTER_EXISTS -eq 0 ]
then
  [ $DRY_RUN == "true" ] || aws --region $REGION rds restore-db-cluster-from-snapshot --cli-input-json "$CLUSTER_JSON"
  echo "Copying cluster ${CLUSTER} to ${CLUSTER_TMP}......In process"
else
  echo "WARNING: Cluster ${CLUSTER_TMP} exists"
fi

####==================== INSTANCE COUNT INFO =================================#####

INSTANCES_COUNT=$( aws --region $REGION rds describe-db-instances --filter "Name=db-cluster-id,Values=${CLUSTER}" | \
  jq -cr '.DBInstances | length' \
)
echo "Cluster ${CLUSTER} have ${INSTANCES_COUNT} instances"

####==================== Coping instances =================================#####

readarray -t INSTANCES < <( aws --region $REGION rds describe-db-instances --filter "Name=db-cluster-id,Values=${CLUSTER}" | \
                              jq -cr '.DBInstances[].DBInstanceIdentifier')

for INSTANCE in "${INSTANCES[@]}"; do

  TMP_INSTANCE_EXISTS=$( aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}${TMP_SUFFIX}" | \
                          jq -cr '.DBInstances | length' )

  if [ $TMP_INSTANCE_EXISTS -eq 0 ]
  then
    INSTANCE_JSON=$( aws --region $REGION rds describe-db-instances --db-instance-identifier "$INSTANCE" |
                  jq -cM "$INSTANCE_MAP_QUERY" )

    [ $DRY_RUN == "true" ] || aws --region $REGION rds create-db-instance --cli-input-json "$INSTANCE_JSON"
    echo "Copying instance $INSTANCE from ${CLUSTER} to ${CLUSTER_TMP}......In process"
  else
      echo "WARNING: Instance ${INSTANCE}${TMP_SUFFIX} exists"
  fi
done

####==================== Waiting cluster ready =================================#####

while true; do
  CLUSTER_TMP_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER_TMP" | \
    jq -cr '.DBClusters[0].Status')

  if [[ $DRY_RUN == "true" ||  "$CLUSTER_TMP_STATUS" == "available" ]]; then
    echo "Copying cluster ${CLUSTER} to ${CLUSTER_TMP}......Done"
    break;
  fi

  echo "Copying cluster ${CLUSTER} to ${CLUSTER_TMP}......In process"
  sleep ${SLEEP}
done

####==================== Waiting instances ready =================================#####

while true; do
  COUNT_NOT_READY_INSTANCES=$(aws --region $REGION rds describe-db-instances --filter "Name=db-cluster-id,Values=${CLUSTER_TMP}" | \
    jq -cr '.DBInstances | map( select( .DBInstanceStatus != "available" )) | length')

  if [[ $DRY_RUN == "true" || "$COUNT_NOT_READY_INSTANCES" == "0" ]]; then
    echo "Copying of ${INSTANCES_COUNT} instances from cluster ${CLUSTER} to ${CLUSTER_TMP} cluster......Done"
    break;
  fi

  echo "$COUNT_NOT_READY_INSTANCES instances in ${CLUSTER_TMP} is not ready yet"
  sleep ${SLEEP}
done

####==================== Reset master password =================================#####

echo "Reset master password for cluster ${CLUSTER_TMP}"

[ $DRY_RUN == "true" ] || aws --region $REGION rds modify-db-cluster \
                              --db-cluster-identifier "${CLUSTER_TMP}" \
                              --master-user-password "${MASTER_PASSWORD}" \
                              --apply-immediately

sleep ${SLEEP}

while true; do
  CLUSTER_TMP_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER_TMP" | \
    jq -cr '.DBClusters[0].Status')

  if [[ $DRY_RUN == "true" ||  "$CLUSTER_TMP_STATUS" == "available" ]]; then
    echo "Changing master password for cluster ${CLUSTER_TMP}......Done"
    break;
  fi

  echo "Changing master password for cluster ${CLUSTER_TMP}......In process"
  sleep ${SLEEP}
done

####==================== Rename cluster =================================#####

####==================== Current to delete =================================#####

echo "Rename cluster ${CLUSTER} to ${CLUSTER_TO_DELETE}"

[ $DRY_RUN == "true" ] || aws --region $REGION rds modify-db-cluster \
                              --db-cluster-identifier "${CLUSTER}" \
                              --new-db-cluster-identifier "${CLUSTER_TO_DELETE}" \
                              --apply-immediately

while true; do
  CLUSTER_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER" | \
    jq -cr '.DBClusters[0].Status')

  if [[ $DRY_RUN == "true" ||  "$CLUSTER_STATUS" == "renaming" ]]; then
    echo "Rename cluster ${CLUSTER} to ${CLUSTER_TO_DELETE}......In process"
    break;
  fi

  echo "Rename cluster ${CLUSTER} to ${CLUSTER_TO_DELETE}......Waiting to start"
  sleep 1
done

####==================== Wait Cluster to delete became available =================================#####

while true; do
  CLUSTER_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER_TO_DELETE" | \
    jq -cr '.DBClusters[0].Status')

  if [[ $DRY_RUN == "true" ||  "$CLUSTER_STATUS" == "available" ]]; then
    echo "Cluster ${CLUSTER_TO_DELETE}......Available"
    break;
  fi

  echo "Cluster ${CLUSTER_TO_DELETE}......not ready"
  sleep 1
done

####==================== TMP to Current =================================#####

echo "Rename cluster ${CLUSTER_TMP} to ${CLUSTER}"

[ $DRY_RUN == "true" ] || aws --region $REGION rds modify-db-cluster \
                              --db-cluster-identifier "${CLUSTER_TMP}" \
                              --new-db-cluster-identifier "${CLUSTER}" \
                              --apply-immediately

while true; do
  CLUSTER_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER_TMP" | \
    jq -cr '.DBClusters[0].Status')

  if [[ $DRY_RUN == "true" ||  "$CLUSTER_STATUS" == "renaming" ]]; then
    echo "Rename cluster ${CLUSTER_TMP} to ${CLUSTER}......In process"
    break;
  fi

  echo "Rename cluster ${CLUSTER_TMP} to ${CLUSTER}......Waiting to start"
  sleep 1
done

####==================== Wait Cluster became available =================================#####

while true; do
  CLUSTER_STATUS=$(aws --region $REGION rds describe-db-clusters --db-cluster-identifier "$CLUSTER" | \
    jq -cr '.DBClusters[0].Status')

  if [[ $DRY_RUN == "true" ||  "$CLUSTER_STATUS" == "available" ]]; then
    echo "Cluster ${CLUSTER}......Available"
    break;
  fi

  echo "Cluster ${CLUSTER}......not ready"
  sleep 1
done


####==================== Rename to delete instances =================================#####

for INSTANCE in "${INSTANCES[@]}"; do

  TMP_INSTANCE_EXISTS=$( aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}" | \
                          jq -cr '.DBInstances | length' )

  if [ $TMP_INSTANCE_EXISTS -eq 1 ]
  then
    [ $DRY_RUN == "true" ] ||  aws --region $REGION rds modify-db-instance \
                                    --db-instance-identifier "$INSTANCE" \
                                    --new-db-instance-identifier "${INSTANCE}${TO_DELETE_SUFFIX}" \
                                    --apply-immediately
    echo "Rename instance $INSTANCE to ${INSTANCE}${TO_DELETE_SUFFIX}"

    while true; do
      INSTANCE_STATUS=$(aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}" | \
      jq -cr '.DBInstances[].DBInstanceStatus')

      if [[ $DRY_RUN == "true" ||  "$INSTANCE_STATUS" == "renaming" ]]; then
        echo "Rename instance $INSTANCE to ${INSTANCE}${TO_DELETE_SUFFIX}......In process"
        break;
      fi

      echo "Rename instance $INSTANCE to ${INSTANCE}${TO_DELETE_SUFFIX}......Waiting to start"
      sleep 1
    done

    while true; do
      INSTANCE_STATUS=$(aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}${TO_DELETE_SUFFIX}" | \
      jq -cr '.DBInstances[].DBInstanceStatus')

      if [[ $DRY_RUN == "true" ||  "$INSTANCE_STATUS" == "available" ]]; then
        echo "Instance ${INSTANCE}${TO_DELETE_SUFFIX}......Available"
        break;
      fi

      echo "Instance ${INSTANCE}${TO_DELETE_SUFFIX}......Not ready"
      sleep 1
    done

  else
      echo "WARNING: Instance ${INSTANCE} not exists"
  fi

done

####==================== Rename TMP to normal instances =================================#####

for INSTANCE in "${INSTANCES[@]}"; do

  TMP_INSTANCE_EXISTS=$( aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}${TMP_SUFFIX}" | \
                          jq -cr '.DBInstances | length' )

  if [ $TMP_INSTANCE_EXISTS -eq 1 ]
  then
    [ $DRY_RUN == "true" ] ||  aws --region $REGION rds modify-db-instance \
                                    --db-instance-identifier "${INSTANCE}${TMP_SUFFIX}" \
                                    --new-db-instance-identifier "${INSTANCE}" \
                                    --apply-immediately
    echo "Rename instance ${INSTANCE}${TMP_SUFFIX} to ${INSTANCE}"

    while true; do
      INSTANCE_STATUS=$(aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}${TMP_SUFFIX}" | \
      jq -cr '.DBInstances[].DBInstanceStatus')

      if [[ $DRY_RUN == "true" ||  "$INSTANCE_STATUS" == "renaming" ]]; then
        echo "Rename instance ${INSTANCE}${TMP_SUFFIX} to ${INSTANCE}......In process"
        break;
      fi

      echo "Rename instance ${INSTANCE}${TMP_SUFFIX} to ${INSTANCE}......Waiting to start"
      sleep 1
    done

    while true; do
      INSTANCE_STATUS=$(aws --region $REGION rds describe-db-instances --filter "Name=db-instance-id,Values=${INSTANCE}" | \
      jq -cr '.DBInstances[].DBInstanceStatus')

      if [[ $DRY_RUN == "true" ||  "$INSTANCE_STATUS" == "available" ]]; then
        echo "Instance ${INSTANCE}......Available"
        break;
      fi

      echo "Instance ${INSTANCE}......Not ready"
      sleep 1
    done

  else
      echo "WARNING: Instance ${INSTANCE}${TMP_SUFFIX} not exists"
  fi


done

echo "......................................................... Done"