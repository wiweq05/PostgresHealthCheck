#!/bin/bash
# **README**
#1. Copy script on Amazon EC2 Linux instance with AWS CLI configured, and psql client installed with accessibility to RDS/Aurora Postgres instance
#2. Make script executable: chmod +x pg_health_check.sh
#3. Run the script: ./pg_health_check.sh
#4. Use the RDS PostgreSQL or Aurora PostgreSQL Writer instance endpoint URL for connection
#5. The database user should have READ access on all of the tables to get better metrics
#6. It will take around 2-3 mins to run (depending on size of instance), and generate html report:  <CompanyName>_<DatabaseIdentifier>_report_<date>.html
#7. Share the report with your AWS Technical Account Manager.
#8. This script works well for PostgreSQL 13 and newer versions. 
#################
# Author: Vivek Singh, Principal Postgres Specialist Technical Account Manager, AWS
# V-24 : JUL7 2024
#################
clear
echo -n -e "RDS PostgreSQL instance endpoint URL or Aurora PostgreSQL Writer endpoint URL: "
read EP
echo -n -e "Port: "
read RDSPORT
echo -n -e "Database Name: "
read DBNAME
echo -n -e "RDS Master User Name: "
read MASTERUSER
echo -n -e "Password: "
read -s  MYPASS
echo  ""
echo -n -e "Company Name (with no space): "
read COMNAME
RDSNAME="${EP%%.*}"
html=${COMNAME}_${RDSNAME}_report_$(date +"%m-%d-%y").html

PSQLCL="psql -h $EP  -p $RDSPORT -U $MASTERUSER $DBNAME"
PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; SELECT now()" >/dev/null 2>&1
if [ "$?" -gt "0" ]; then
echo "Instance $EP cannot be connected. Stopping the script"
sleep 1
exit
else
echo "Instance is running. Creating report..."
fi

if
PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; select name from pg_settings" | cut -d \| -f 1 | grep -qw apg_buffer_invalid_lookup_strategy; then
DBTYPE="aurora-postgresql"
else DBTYPE="postgres"
fi

#SQLs Used In the Script:

#Idele Connections
SQL1="select count(*) from pg_stat_activity where state='idle';"

#Top 5 Databases Size
SQL2=" SELECT "DB_Name", "Pretty_DB_size" from (SELECT pg_database.datname as "DB_Name",
pg_database_size(pg_database.datname) as "DB_Size",
pg_size_pretty(pg_database_size(pg_database.datname)) as "Pretty_DB_size"
 FROM pg_database ORDER by 2 DESC limit 5) as a;"

#Total Size of All Databases
SQL3="SELECT pg_size_pretty(SUM(pg_database_size(pg_database.datname))) as "Total_DB_size"
 FROM pg_database;"

#Top 10 biggest tables
SQL4="select schemaname as table_schema,
    relname as table_name,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    pg_size_pretty(pg_relation_size(relid)) as data_size,
    pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid))
      as external_size
from pg_catalog.pg_statio_user_tables where schemaname not in ('pg_catalog', 'information_schema')
order by pg_total_relation_size(relid) desc,
         pg_relation_size(relid) desc
limit 10;"

#Duplticate Indexes
SQL5="SELECT pg_size_pretty(SUM(pg_relation_size(idx))::BIGINT) AS SIZE,
       (array_agg(idx))[1] AS idx1, (array_agg(idx))[2] AS idx2,
       (array_agg(idx))[3] AS idx3, (array_agg(idx))[4] AS idx4
FROM (
    SELECT indexrelid::regclass AS idx, (indrelid::text ||E'\n'|| indclass::text ||E'\n'|| indkey::text ||E'\n'||
                                         COALESCE(indexprs::text,'')||E'\n' || COALESCE(indpred::text,'')) AS KEY
    FROM pg_index) sub
GROUP BY KEY HAVING COUNT(*)>1
ORDER BY SUM(pg_relation_size(idx)) DESC LIMIT 10;"

#Unused Indexes
SQL6="SELECT s.schemaname,
       s.relname AS tablename,
       s.indexrelname AS indexname,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size
FROM pg_catalog.pg_stat_user_indexes s
   JOIN pg_catalog.pg_index i ON s.indexrelid = i.indexrelid
WHERE s.idx_scan = 0      -- has never been scanned
  AND 0 <>ALL (i.indkey)  -- no index column is an expression
  AND NOT EXISTS          -- does not enforce a constraint
         (SELECT 1 FROM pg_catalog.pg_constraint c
          WHERE c.conindid = s.indexrelid)
ORDER BY pg_relation_size(s.indexrelid) DESC limit 10;"

#Database Age
SQL7="SELECT datname, 
       age(datfrozenxid), 
       2^31-1000000-age(datfrozenxid) as remaining
  FROM pg_database
 ORDER BY 3 limit 5;"

#Most Bloated Tables
SQL8="SELECT
  current_database(), schemaname, tablename, /*reltuples::bigint, relpages::bigint, otta,*/
  ROUND((CASE WHEN otta=0 THEN 0.0 ELSE sml.relpages::FLOAT/otta END)::NUMERIC,1) AS tbloat,
  CASE WHEN relpages < otta THEN 0 ELSE bs*(sml.relpages-otta)::BIGINT END AS wastedbytes,
  iname, /*ituples::bigint, ipages::bigint, iotta,*/
  ROUND((CASE WHEN iotta=0 OR ipages=0 THEN 0.0 ELSE ipages::FLOAT/iotta END)::NUMERIC,1) AS ibloat,
  CASE WHEN ipages < iotta THEN 0 ELSE bs*(ipages-iotta) END AS wastedibytes
FROM (
  SELECT
    schemaname, tablename, cc.reltuples, cc.relpages, bs,
    CEIL((cc.reltuples*((datahdr+ma-
      (CASE WHEN datahdr%ma=0 THEN ma ELSE datahdr%ma END))+nullhdr2+4))/(bs-20::FLOAT)) AS otta,
    COALESCE(c2.relname,'?') AS iname, COALESCE(c2.reltuples,0) AS ituples, COALESCE(c2.relpages,0) AS ipages,
    COALESCE(CEIL((c2.reltuples*(datahdr-12))/(bs-20::FLOAT)),0) AS iotta -- very rough approximation, assumes all cols
  FROM (
    SELECT
      ma,bs,schemaname,tablename,
      (datawidth+(hdr+ma-(CASE WHEN hdr%ma=0 THEN ma ELSE hdr%ma END)))::NUMERIC AS datahdr,
      (maxfracsum*(nullhdr+ma-(CASE WHEN nullhdr%ma=0 THEN ma ELSE nullhdr%ma END))) AS nullhdr2
    FROM (
      SELECT
        schemaname, tablename, hdr, ma, bs,
        SUM((1-null_frac)*avg_width) AS datawidth,
        MAX(null_frac) AS maxfracsum,
        hdr+(
          SELECT 1+COUNT(*)/8
          FROM pg_stats s2
          WHERE null_frac<>0 AND s2.schemaname = s.schemaname AND s2.tablename = s.tablename
        ) AS nullhdr
      FROM pg_stats s, (
        SELECT
          (SELECT current_setting('block_size')::NUMERIC) AS bs,
          CASE WHEN SUBSTRING(v,12,3) IN ('8.0','8.1','8.2') THEN 27 ELSE 23 END AS hdr,
          CASE WHEN v ~ 'mingw32' THEN 8 ELSE 4 END AS ma
        FROM (SELECT version() AS v) AS foo
      ) AS constants
      GROUP BY 1,2,3,4,5
    ) AS foo
  ) AS rs
  JOIN pg_class cc ON cc.relname = rs.tablename
  JOIN pg_namespace nn ON cc.relnamespace = nn.oid AND nn.nspname = rs.schemaname AND nn.nspname <> 'information_schema'
  LEFT JOIN pg_index i ON indrelid = cc.oid
  LEFT JOIN pg_class c2 ON c2.oid = i.indexrelid
) AS sml
ORDER BY wastedbytes DESC LIMIT 10;"

#Top 10 biggest tables last vacuumed
SQL9="SELECT schemaname, relname, cast(last_vacuum as date), cast(last_autovacuum as date), cast(last_analyze as date), cast(last_autoanalyze as date), pg_size_pretty(pg_total_relation_size(relid)) as table_total_size from pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC limit 10;"

#Key PostgreSQL Parameters
SQL10="select name, setting, source, short_desc from pg_settings where name in ('max_connections', 'shared_buffers', 'checkpoint_timeout','max_wal_size','default_statistics_target','work_mem','maintenance_work_mem','random_page_cost','rds.logical_replication','wal_keep_segments','hot_standby_feedback'); "

#Performance Parameters
SQL11="select name, setting from pg_settings where name IN ('shared_buffers', 'effective_cache_size', 'log_temp_files', 'work_mem', 'shared_preload_libraries', 'maintenance_work_mem', 'default_statistics_target', 'random_page_cost', 'rds.logical_replication','wal_keep_segments');"

#pg_stat_statements top queries
#Top 10 short queries consuming CPU
SQL12="SELECT  userid::regrole as user,
              datname as DB_name,
              substring(query, 1, 50) AS short_query,
              round(( total_plan_time + total_exec_time )::numeric, 2) AS total_ime,
              calls,
              round(( total_plan_time + total_exec_time )::numeric, 2) AS mean,
              round((100 * ( total_plan_time + total_exec_time ) /
              sum(( total_plan_time + total_exec_time )::numeric) OVER ())::numeric, 2) AS percentage_cpu
FROM  pg_stat_statements p, pg_database d
WHERE p.dbid=d.oid
ORDER BY percentage_cpu DESC
LIMIT 10;"

#Top 10 Read Queries
SQL13="SELECT
  userid::regrole as user
  ,datname as DB_name
  ,left(query, 50) AS short_query
  ,round(( total_plan_time + total_exec_time )::numeric, 2) AS total_time
  ,calls
  ,shared_blks_read
  ,shared_blks_hit
  ,round((100.0 * shared_blks_hit/nullif(shared_blks_hit + shared_blks_read, 0))::numeric,2) AS hit_percent
FROM  pg_stat_statements p, pg_database d
WHERE p.dbid=d.oid
ORDER BY shared_blks_read DESC LIMIT 10;"

#Top 10 UPDATE/DELETE tables
SQL15="SELECT relname
,round(upd_percent::numeric, 2) AS update_percent
,round(del_percent::numeric, 2) AS delete_percent
,round(ins_percent::numeric, 2) AS insert_percent
 from (
SELECT relname
,100*cast(n_tup_upd AS numeric) / (n_tup_ins + n_tup_upd + n_tup_del) AS upd_percent
,100*cast(n_tup_del AS numeric) / (n_tup_ins+ n_tup_upd + n_tup_del) AS del_percent
,100*cast(n_tup_ins AS numeric) / (n_tup_ins + n_tup_upd + n_tup_del) AS ins_percent
FROM pg_stat_user_tables
WHERE (n_tup_ins + n_tup_upd + n_tup_del) > 0
ORDER BY coalesce(n_tup_upd,0)+coalesce(n_tup_del,0) desc ) a limit 10;"

#Top 10 Read IO tables
SQL16="SELECT
relname
,round((100.0 * heap_blks_hit/nullif(heap_blks_hit + heap_blks_read, 0))::numeric,2) AS hit_percent
,heap_blks_hit
,heap_blks_read
FROM pg_statio_user_tables
WHERE (heap_blks_hit + heap_blks_read) >0
ORDER BY coalesce(heap_blks_hit,0)+coalesce(heap_blks_read,0) desc limit 10;"

#Logging parameters
SQL17="select name, setting, short_desc from pg_settings where name in ('log_connections','log_disconnections','log_checkpoints','log_min_duration_statement','log_statement','log_temp_files','log_autovacuum_min_duration');"

#Aurora specific parameters
SQL18="select name, setting, short_desc from pg_settings where name like '%apg%';"

#Top 5 aged tables
SQL19="SELECT c.relnamespace::regnamespace as schema_name,
       c.relname as table_name,
       greatest(age(c.relfrozenxid),age(t.relfrozenxid)) as age,
       2^31-1000000-greatest(age(c.relfrozenxid),age(t.relfrozenxid)) as remaining
  FROM pg_class c
  LEFT JOIN pg_class t ON c.reltoastrelid = t.oid
 WHERE c.relkind IN ('r', 'm')
 ORDER BY 4 limit 5;"

#Top 10 temporary space writing queries
SQL20="SELECT userid::regrole, datname as DB_name, substring(query, 1, 50) AS short_query, interval '1 millisecond' * total_exec_time AS total_exec_time_ms, total_exec_time / calls AS avg_exec_time_ms, temp_blks_written FROM  pg_stat_statements p, pg_database d
    order by temp_blks_written desc
    limit 10;"

#Top 10 temporary space reading queries
SQL21="SELECT userid::regrole, datname as DB_name, substring(query, 1, 50) AS short_query, interval '1 millisecond' * total_exec_time AS total_exec_time_ms, total_exec_time / calls AS avg_exec_time_ms, temp_blks_read FROM  pg_stat_statements p, pg_database d
    order by temp_blks_read desc
    limit 10;"
	
html=${COMNAME}_${RDSNAME}_report_$(date +"%m-%d-%y").html
#Generating HTML file
echo "<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">" > $html
echo "<html>" >> $html
echo "<link rel="stylesheet" href="https://unpkg.com/purecss@0.6.2/build/pure-min.css">" >> $html
echo "<body style="font-family:'Verdana'" bgcolor="#F8F8F8">" >> $html
echo "<fieldset>" >> $html
echo "<table><tr> <td width="20"></td> <td>" >>$html
echo "<h1><font face="verdana" color="#0099cc"><center><u>PostgreSQL Health Check Report For $COMNAME</u></center></font></h1></color>" >> $html
echo "</fieldset>" >> $html

echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Date:</font> `date +%b\ %d,\ %Y` " >>$html
echo "<br>" >> $html

echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Instance Details:  </font>" >>$html
echo "<br>" >> $html
echo "Postgres Endpoint URL: $EP" >> $html
echo "<br>" >> $html

#shared_buffers percentage
NUMSBRAW=`PGPASSWORD=$MYPASS $PSQLCL  -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; select setting from pg_settings where name='shared_buffers';"|sed -n 3p`
DBCLASS=`aws rds describe-db-instances --db-instance-identifier $RDSNAME | grep Class| awk '{ print $2 }'|sed 's/"//g' |sed 's/db.//g' |sed 's/,//g'`
NUM2=1048576
NUM3=$((NUMSBRAW*8 / NUM2))
SBNUM=$((NUM3*1024))
INSTCLASS=`aws rds describe-db-instances --db-instance-identifier $RDSNAME | grep Class| awk '{ print $2 }'|sed 's/"//g' |sed 's/db.//g' |sed 's/,//g'`
TOTALRAM=`aws ec2 describe-instance-types --instance-types $INSTCLASS | grep SizeInMiB | awk '{ print $2 }'`
RATIOSB=$((SBNUM*100/$TOTALRAM))
ECHOSB="Shared_buffers is $NUM3 GB and $RATIOSB% of total RAM."


echo "PostgreSQL Engine Version: " >>$html
echo `PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; SELECT version()" |  grep -oP '(?<=PostgreSQL).*(?=on)'`  >>$html
echo "<br>" >> $html
echo "Maximum Connections :" >>$html
echo  `PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; show max_connections" | awk 'FNR== 3'`  >>$html
echo "<br>" >> $html
echo "Curent Total Connections: " >>$html
echo `PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; select count(*) from pg_stat_activity;" | awk 'FNR== 3'`  >>$html
echo "<br>" >> $html
echo "Idle Connections : `PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; $SQL1" | awk 'FNR== 3'` " >>$html
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Instance Configuration: </font>" >>$html
aws rds describe-db-instances --db-instance-identifier $RDSNAME | grep 'Allocated\|Public\|MonitoringInterval\|MultiAZ\|\StorageType\|\BackupRetentionPeriod\|DBInstanceClass'|sed "s/\"//g"|sed "s/\,//g"| sed "s/\PubliclyAccessible/<br>Publicly Accessible/g"| sed "s/\MonitoringInterval/<br>EM Monitoring Interval/g" | sed "s/\MultiAZ/<br>Multi AZ Enabled?/g" | sed "s/\AllocatedStorage/<br>Allocated Storage (GB)/g" |  sed "s/\DBInstanceClass/<br>DB Instance Class/g" | sed "s/\BackupRetentionPeriod/<br>Backup Retention Period/g" | sed "s/\StorageType/<br>Storage Type/g" |  sed "s/\ B//g"|sed "s/\gp2/GP2/g" >>$html
echo "<br>" >> $html
echo "<br>" >> $html

echo "<font face="verdana" color="#ff6600">PostgreSQL Health Score Card: </font>" >>$html
CURRENT_VERSION=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT version()" |  grep -oP '(?<=PostgreSQL).*(?=on)'`

#Current Major version
CURR_MAJOR_VERSION=`PGPASSWORD=$MYPASS $PSQLCL -c "Select version();" | grep -oP '(?<=PostgreSQL).*(?=on)' |grep -oP '.*?(?=\.)'`

#Minor version
MAX_MINOR_VERSION=`aws rds describe-db-engine-versions --engine $DBTYPE --engine-version $CURRENT_VERSION --query "DBEngineVersions[*].ValidUpgradeTarget[].[EngineVersion,IsMajorVersionUpgrade]" --output text | grep False |sort -n | tail -1| awk '{print $1}'`

#Max major version
MAX_MAJOR_VERSION=`aws rds describe-db-engine-versions --engine $DBTYPE --query "DBEngineVersions[].EngineVersion" --output text | awk '{print $NF}'|grep -oP '.*?(?=\.)'`

SCORE3=`aws rds describe-db-instances --db-instance-identifier $RDSNAME  --query '*[].["StorageEncrypted"]' --output text`

SCORE4=`if [[ "CURR_MAJOR_VERSION" == 11 ]]; then echo "True"; else echo "False"; fi`

SCORE5=`aws rds describe-db-instances --db-instance-identifier $RDSNAME  --query '*[].["MonitoringInterval"]' --output text`

SCORE6=`aws rds describe-db-instances --db-instance-identifier $RDSNAME  --query '*[].["PerformanceInsightsEnabled"]' --output text`

SCORE7=`aws rds describe-db-instances  --db-instance-identifier $RDSNAME  --query '*[].["PerformanceInsightsRetentionPeriod"]' --output text`

SCORE8=`aws rds describe-db-instances  --db-instance-identifier $RDSNAME --query '*[].["DBInstanceClass"]' --output text | head -c 5 | tail -c 2`

SCORE9=`aws rds describe-db-instances  --db-instance-identifier $RDSNAME  --query '*[].["MultiAZ"]' --output text`

SCORE10=`aws rds describe-db-instances  --db-instance-identifier $RDSNAME  --query '*[].["DeletionProtection"]' --output text`

SCORE11=`aws rds describe-db-instances  --db-instance-identifier $RDSNAME --query '*[].["PubliclyAccessible"]' --output text`

SCORE12=`aws rds describe-db-instances --db-instance-identifier $RDSNAME --query 'DBInstances[*].DBParameterGroups[*].DBParameterGroupName'  --output text`

SCORE13=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='work_mem';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

SCORE14=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='idle_in_transaction_session_timeout';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

SCORE15=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='log_temp_files';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

SCORE16=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='autovacuum';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

SCORE17=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='log_min_duration_statement';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

SCORE18=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='log_statement';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`

SCORE19=`PGPASSWORD=$MYPASS $PSQLCL -c "SELECT setting from pg_settings where name='log_autovacuum_min_duration';" | awk 'c&&!--c;/----/{c=1}'|sed 's/ //g'`
echo "<table border=1 cellpadding=3 cellspacing=0>
  <tr>
    <td><font face="verdana" color="#000000"><b>Item</b></font></td>
    <td><font face="verdana" color="#000000"><b>Description</b></font></td>
	<td><font face="verdana" color="#000000"><b>Current score</b></font></td>
    <td><font face="verdana" color="#000000"><b>Max score</b></font></td>
  </tr>" >> $html
i=0
if [[ "$CURR_MAJOR_VERSION" == "$MAX_MAJOR_VERSION" ]]; then i1=$((i+5)); else i1=$i; fi
echo "<tr>
    <td>Current major version</td>
    <td>PostgreSQL version of this instance is $CURRENT_VERSION. Current highest major version supported for
   `if [[ "$DBTYPE" == "postgres" ]]; then
    echo "RDS PostgreSQL"
elif [[ "$DBTYPE" == "aurora-postgresql" ]]; then
    echo "Aurora PostgreSQL"
fi`
is $MAX_MAJOR_VERSION.</td>
    <td>$((i1 - i))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$CURRENT_VERSION" == "$MAX_MINOR_VERSION" ]]; then i2=$((i1+5)); else i2=$i1; fi
echo "<tr>
    <td>Current minor version</td>
    <td>PostgreSQL minor versions typically include bug fixes and security fixes, but no functional changes. Highest minor version for 
    `if [[ "$DBTYPE" == "postgres" ]]; then
    echo "RDS PostgreSQL"
elif [[ "$DBTYPE" == "aurora-postgresql" ]]; then
    echo "Aurora PostgreSQL"
fi`  $CURR_MAJOR_VERSION is $MAX_MINOR_VERSION. </td>
    <td>$((i2 - i1))</td>
    <td>5</td>
  </tr>" >> $html
if [[ $SCORE3 = "True" ]]; then i3=$((i2+5)); else i3=$i2; fi
echo "<tr>
    <td>Storage Encrypted</td>
    <td>RDS Storage Encrypted encrypts data stored at rest in the underlying storage of database instances.</td>
    <td>$((i3 - i2))</td>
    <td>5</td>
  </tr>" >> $html
if [[ $SCORE4 = "False" ]]; then i4=$((i3+5)); else i4=$i3; fi
echo "<tr>
    <td>RDS Extended Support</td>
    <td>On the RDS end of standard support date, Amazon RDS automatically enrolls databases in RDS Extended Support at an additional cost.</td>
    <td>$((i4 - i3))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE5" -lt 60 ]]; then i5=$((i4+5)); else i5=$i4; fi
echo " <tr>
    <td>Monitoring Interval</td>
    <td>Default value is 60 seconds. Lower value helps troubleshooting the issues better.</td>
    <td>$((i5 - i4))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE6" = "True" ]]; then i6=$((i5+5)); else i6=$i5; fi
echo " <tr>
    <td>Performance Insights Enabled</td>
    <td>RDS Performance Insights is a database performance tuning and monitoring feature that helps quickly assess the load on database, and determine when and where to take action.</td>
    <td>$((i6 - i5))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE7" -gt 7 ]]; then i7=$((i6+5)); else i7=$i6; fi
echo " <tr>
    <td>Performance Insights Retention Period</td>
    <td>Default value is 7 days. Higher value helps troublshooting issues in past.</td>
    <td>$((i7 - i6))</td>
    <td>5</td>
  </tr>" >> $html
if [ "$SCORE8" != "m4" ] && [ "$SCORE8" != "r4" ] && [ "$SCORE8" != "t2" ]; then i8=$((i7+5)); else i8=$i7; fi
echo " <tr>
    <td>DB Instance Class</td>
    <td>DB instance types M4, R4, and T2 are no more supported for new database instances.</td>
    <td>$((i8 - i7))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE9" = "True" ]]; then i9=$((i8+5)); else i9=$i8; fi
echo " <tr>
    <td>Multi AZ</td>
    <td>RDS Multi-AZ is a feature that allows to deploy a database across multiple availability zones (AZs), inclreasing high availability.</td>
    <td>$((i9 - i8))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE10" = "True" ]]; then i10=$((i9+5)); else i10=$i9; fi
echo " <tr>
    <td>Deletion Protection</td>
    <td>Deletion protection is a security feature RDS that prevents users from accidentally or intentionally deleting database instances or clusters.</td>
    <td>$((i10 - i9))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE11" = "False" ]]; then i11=$((i10+5)); else i11=$i10; fi
echo " <tr>
    <td>Publicly Accessible</td>
    <td>A publicly accessible RDS instance is one that has a public IP address and an open security group, allowing anyone on the internet to connect to it.</td>
    <td>$((i11 - i10))</td>
    <td>5</td>
  </tr>" >> $html
if [[ ! ${SCORE12} =~ ^default ]]; then i12=$((i11+5)); else i12=$i11; fi
echo " <tr>
    <td>Parameter Group</td>
    <td>RDS Parameter Group is a collection of parameters that control the configuration and behavior of an RDS instance or cluster.</td>
    <td>$((i12 - i11))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE13" -gt 4096 ]]; then i13=$((i12+5)); else i13=$i12; fi
echo " <tr>
    <td>Parameter work_mem</td>
    <td>Checks if parameter work_mem is set at default value 4MB.</td>
    <td>$((i13 - i12))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE14" -lt 86400000 ]]; then i14=$((i13+5)); else i14=$i13;  fi
echo " <tr>
    <td>Parameter idle_in_transaction_session_timeout</td>
    <td>Checks if parameter idle_in_transaction_session_timeout is set at default value.</td>
    <td>$((i14 - i13))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE15" -ne -1 ]]; then i15=$((i14+5)); else i15=$i14;  fi
echo " <tr>
    <td>Parameter log_temp_files</td>
    <td>Checks if parameter log_temp_files is emabled or not.</td>
    <td>$((i15 - i14))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE16" = "on" ]]; then i16=$((i15+5)); else i16=$i15; fi
echo " <tr>
    <td>Parameter autovacuum</td>
    <td>Checks if parameter autovacuum is turned on or not.</td>
    <td>$((i16 - i15))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE17" -ne -1 ]]; then i17=$((i16+5)); else i17=$i16;  fi
echo " <tr>
    <td>Parameter log_min_duration_statement</td>
    <td>Checks if parameter log_min_duration_statement is emabled or not.</td>
    <td>$((i17 - i16))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE18" != "all"  ]]; then i18=$((i17+5)); else i18=$i17i; fi
echo " <tr>
    <td>Parameter log_statement</td>
    <td>Checks if parameter log_statement is set to ALL or not.</td>
    <td>$((i18 - i17))</td>
    <td>5</td>
  </tr>" >> $html
if [[ "$SCORE19" -ne -1 ]]; then i19=$((i18+5)); else i19=$i18; fi
echo " <tr>
    <td>Parameter log_autovacuum_min_duration</td>
    <td>Checks if parameter log_autovacuum_min_duration is enabled or not.</td>
    <td>$((i19 - i18))</td>
    <td>5</td>
  </tr>" >> $html
if [ "$DBTYPE" == "postgres" ] && [ $RATIOSB > 23 ]; then 
    i20=$((i19+5))
elif [ "$DBTYPE" == "aurora-postgresql" ] && [ $RATIOSB > 65 ]; then
    i20=$((i19+5))
fi
echo "<tr>
    <td>Shared_buffers</td>
    <td>Parameter Checks if parameter Shared_buffers is set at lower than default value.</td>
    <td>$((i20 - i19))</td>
    <td>5</td>
  </tr>" >> $html
echo "<tr>
    <td><font face="verdana" color="#000000"><b>Total points</b></font></td>
    <td></td>
    <td><font face="verdana" color="#000000"><b>$i20</b></font></td>
    <td><font face="verdana" color="#000000"><b>100</b></font></td>
  </tr>" >> $html

echo "</table>" >> $html
echo "<br>" >> $html


#Total Log Size
TLS=`aws rds describe-db-log-files --db-instance-identifier $RDSNAME | grep "Size" | grep -o '[0-9]*' | awk '{n += $1}; END{print n}'`
AGB=1073741824
echo "<font face="verdana" color="#ff6600">Total Size of Log Files:  </font>" >>$html
echo $TLS | sed 's/$/ Bytes/' >>$html
#echo "<br>" >> $html
echo : $((ERT / AGB)) | sed 's/$/ GB/' >>$html
echo "<br>" >> $html

if [[ "$DBTYPE" == "aurora-postgresql" ]]; then 
echo "<font face="verdana" color="#0099cc">Note: In Aurora PostgreSQL, database log files occupy local storage. With verbose logging enabled, it can quickly consume the EBS local storage. Set the CloudWatch alarm for low FreeLocalStorage metrics. If database logs are consuming large space, consider lowering <a href="https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.html#USER_LogAccess.Concepts.PostgreSQL.log_retention_period" target="_blank">rds.log_retention_period</a> to up to 1 day. Default is 3 days. Have an automated job (such as Lambda) to back up the log file externally as soon as they are created. Use <a href="https://www.postgresql.org/about/news/pgbadger-v114-released-2120/" target="_blank">pgBadger</a> to analyze these log files.</font>" >> $html
else
echo "<font face="verdana" color="#0099cc">Note: In RDS PostgreSQL, database log files occupy EBS volume storage. Large size of log files can cause STORAGE FULL issue. If database logs are consuming large space, consider lowering rds.log_retention_period to up to 1 day. Default is 3 days. Have an automated job (such as Lambda) to back up the log file externally as soon as they are created. Use <a href="https://www.postgresql.org/about/news/pgbadger-v114-released-2120/" target="_blank">pgBadger</a> to analyze these log files.</font>" >>$html
fi

echo "<br>" >> $html
echo "<br>" >> $html
DBAGE=`PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; SELECT to_char(max(age(datfrozenxid)),'FM9,999,999,999') FROM pg_database;" | awk 'FNR== 3'|sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
echo "<font face="verdana" color="#ff6600">Maximum Used Transaction IDs:</font> $DBAGE" >>$html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">Note: Set up <a href="https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/creating_alarms.html" target="_blank">CloudWatch alarm</a> for 'MaximumUsedTransactionIDs' at around 1B value.  The value of ~2 billion can cause <a href="https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND" target="_blank">Transaction ID Wraparound failures</a> issues. Please visit this <a href="https://aws.amazon.com/blogs/database/implement-an-early-warning-system-for-transaction-id-wraparound-in-amazon-rds-for-postgresql/" target="_blank">AWS blog</a> for more details on creating this alarm.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
TOTALDBSIZE=`PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; SELECT pg_size_pretty(SUM(pg_database_size(pg_database.datname))) as "Total_DB_size" FROM pg_database" | awk 'FNR== 3'|sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
echo "<font face="verdana" color="#ff6600">Total Size of All Databases:</font> $TOTALDBSIZE" >>$html


echo "<br>" >> $html
echo "<br>" >> $html
TOTALDB=`PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; SELECT count(*) from pg_database" | awk 'FNR== 3'|sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
echo "<font face="verdana" color="#ff6600">Top 5 Databases Size ($TOTALDB):</font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL2
"|sed '$d'|sed '$d' ` " >>$html

echo "<br>" >> $html
echo "<br>" >> $html
TOTALTAB=`PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s'; SELECT count(*) from  information_schema.tables where table_type = 'BASE TABLE' and table_schema NOT IN ('pg_catalog','information_schema');" | awk 'FNR== 3'|sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
echo "<font face="verdana" color="#ff6600">Top 10 Biggest Tables ($TOTALTAB): </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL4
"|sed '$d'|sed '$d' ` " >>$html
echo "<font face="verdana" color="#0099cc">Note: Looking at the access pattern, consider <a href="https://www.postgresql.org/docs/current/ddl-partitioning.html" target="_blank">partitioning</a> large tables for improved query performance, reducing IOs, easier data purge and better autovacuum performance.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
TOTALDUPIND=`PGPASSWORD=$MYPASS $PSQLCL -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
select count(*) from
(
SELECT pg_size_pretty(SUM(pg_relation_size(idx))::BIGINT) AS SIZE,
       (array_agg(idx))[1] AS idx1, (array_agg(idx))[2] AS idx2,
       (array_agg(idx))[3] AS idx3, (array_agg(idx))[4] AS idx4
FROM (
    SELECT indexrelid::regclass AS idx, (indrelid::text ||E'\n'|| indclass::text ||E'\n'|| indkey::text ||E'\n'||
                                         COALESCE(indexprs::text,'')||E'\n' || COALESCE(indpred::text,'')) AS KEY
    FROM pg_index) sub
GROUP BY KEY HAVING COUNT(*)>1
ORDER BY SUM(pg_relation_size(idx))
) ti;
" | awk 'FNR== 3'|sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'`
echo "<font face="verdana" color="#ff6600">Duplicate Indexes ($TOTALDUPIND): </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL5
"|sed '$d'|sed '$d' ` " >>$html
echo "<font face="verdana" color="#0099cc">Note: For better write performance, saving write IOs, saving storage, look at the index definitions and consider dropping duplicate indexes." >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Unused Indexes: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL6
"|sed '$d'|sed '$d' ` " >>$html
echo "<font face="verdana" color="#0099cc">Note: For better write performance, saving write IOs, saving storage, look at the index definitions and consider dropping unused indexes." >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 5 Database Age: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL7
"|sed '$d'|sed '$d' ` " >>$html
echo "<font face="verdana" color="#0099cc">Note: Please visit <a href="https://www.postgresql.org/docs/current/routine-vacuuming.html" target="_blank">PostgreSQL doc</a> for more details on database age.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 5 Table age: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL19
"|sed '$d'|sed '$d' ` " >>$html
echo "<font face="verdana" color="#0099cc">Note: Please visit <a href="https://www.postgresql.org/docs/current/routine-vacuuming.html" target="_blank">PostgreSQL doc</a> for more details on table age. Consider VACUUM FREEZE on the highly aged tables.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Most Bloated Tables: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL8
"|sed '$d'|sed '$d' ` " >>$html
echo "<font face="verdana" color="#0099cc">Note: Consider <a href="https://www.postgresql.org/docs/current/sql-vacuum.html" target="_blank">VACUUM</a> highly bloated tables during off peak hours. Use Aurora/RDS PostgreSQL supported <a href="https://www.postgresql.org/docs/current/runtime-config-autovacuum.html" target="_blank">pg_cron</a> extension to schedule manual VACUUM job. Consider recreating bloated indexes. Use <a href="https://www.postgresql.org/docs/current/runtime-config-autovacuum.html" target="_blank">pg_repack</a> extension to reclaim space.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Biggest Tables Last Vacuumed: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL9
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: If large tables are not autovacuumed recently, consider logging autovacuum activities. Consider VACCUM these tables during off peak hours. </font>" >> $html

sleep 1
echo "Still working ..."
sleep 1

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 UPDATE/DELETE Tables: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL15
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: For better VACUUM and ANALYZE performance on tables with high bloat and high UPDATE/DELETE operations, modify autovacuum parameters on table level. Changing parameters on instance level will impact all tables in the databases.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600"><a href="https://www.postgresql.org/docs/current/runtime-config-autovacuum.html" target="_blank">Vacuum</a> Parameters: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
select name, setting, source, context from pg_settings where name like 'autovacuum%'
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Please visit <a href="https://aws.amazon.com/blogs/database/understanding-autovacuum-in-amazon-rds-for-postgresql-environments/" target="_blank">AWS blog</a>  for understanding autovacuum in Aurora/ RDS PostgreSQL enviroments and, this <a href="https://aws.amazon.com/blogs/database/a-case-study-of-tuning-autovacuum-in-amazon-rds-for-postgresql/" target="_blank">AWS blog</a> for autovacuum parameter tuning. Modify parameter rds.force_autovacuum_logging_level parameter to warning and set the log_autovacuum_min_duration parameter to a value from 1,000 to 5,000 milliseconds to log autovacuum activites.</font>" >> $html


echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Key PostgreSQL Parameters: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL10
"|sed '$d'|sed '$d' ` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Consider increaswing work_mem (default value 4MB) for better performance of complex sorting/hashing. Consider increasing maintenance_work_mem for better performance on maintenance tasks such as VACUUM, RESTORE, CREATE INDEX, ADD FOREIGN KEY. $ECHOSB If working data set is bigger than shared_buffers, modify size by using extension <a href="https://www.postgresql.org/docs/current/pgbuffercache.html" target="_blank">pg_buffercache</a> Lower than default value can cause high Read IOs and performance impact of read workloads. Watch closely  CloudWatch metric FreeableMemory while changing memory paramters.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600"><a href="https://www.postgresql.org/docs/current/runtime-config-logging.html" target="_blank">Logging</a> Parameters: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL17
"|sed '$d'|sed '$d' ` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Consider enabling log_min_duration_statement to log slow running queries. Value of 5000 logs queries running more than for 5 seconds. Enabling 'log_statement' paramter logs none (off), ddl, mod, or all statements). Verbose logging can increase the log file sizes. Please visit this <a href="https://aws.amazon.com/blogs/database/working-with-rds-and-aurora-postgresql-logs-part-1/" target="_blank">AWS blog</a> for more details on working with RDS/Aurora logs, and this <a href="https://aws.amazon.com/blogs/database/part-2-audit-aurora-postgresql-databases-using-database-activity-streams-and-pgaudit/?nc1=b_nrp" target="_blank">AWS blog</a> for more details on Aurora PostgreSQL <a href="https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/DBActivityStreams.Overview.html" target="_blank">'Database Activity Streams'</a> and <a href="https://aws.amazon.com/premiumsupport/knowledge-center/rds-postgresql-pgaudit/" target="_blank">pgAudit</a>. Enable log_temp_files to log temporary files names and sizes.</font>" >> $html

echo "<br>" >> $html
if [[ "$DBTYPE" == "aurora-postgresql" ]]; then 
echo "<font face="verdana" color="#ff6600">Aurora PostgreSQL Specific Parameters: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL18
"|sed '$d'|sed '$d' ` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Please visit this <a href="https://aws.amazon.com/blogs/database/amazon-aurora-postgresql-parameters-part-3-optimizer-parameters/" target="_blank">AWS blog</a> for more details on Aurora PostgreSQL optimizer parameters." >> $html
echo "" >> $html
else
echo "" >> $html
fi
echo "<br>" >> $html

echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Read IO Tables: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL16
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Pick the tables with low 'hit_percent' and consider about partitioning, optimizing queries related to those tables. Also consider using <a href="https://www.postgresql.org/docs/current/pgprewarm.html" target="_blank">pg_prewarm</a> extension to load relation data into buffer cache.</font>" >> $html


if
PGPASSWORD=$MYPASS $PSQLCL -c "select extname FROM pg_extension" | cut -d \| -f 1 | grep -qw pg_stat_statements; then
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 CPU Consuming SQLs: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL12
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Run EXPLAIN plan on the top CPU consuming queries and optimize. Please watch this <a href="https://www.youtube.com/watch?v=XKPHbYe-fHQ" target="_blank">AWS video</a> on RDS/Aurora PostgreSQL query tuning. This AWS <a href="https://aws.amazon.com/premiumsupport/knowledge-center/rds-aurora-postgresql-high-cpu/" target="_blank">knowledge-center article</a> discusses about troubleshooting high CPU issue at RDS/Aurora PostgreSQL. </font>" >> $html



echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Read I/O Queries: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL13
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Run EXPLAIN plan on the top 10 Read queries with low 'hit_percent'. Focus on proper indexing, partitioning, checkpoints and VACUUM ANALYZE on heavily used tables. Look at CloudWatch metric 'BufferCacheHitRatio'. Lower the value, higher the Read IO cost.</font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Temporary Space Written Queries: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL20
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Run EXPLAIN plan on the top 10 temporary space written queries. In the EXPLAIN plan, look for pattern:   Sort Method: external merge  Disk: 47224kB. This shows that the query will create around 50mB of temp files. In query session use SET LOCAL work_mem = '55MB';. Look at DML operations consuming temporary space. temp_file_limit parameter cancels any query exceeding the size of temp_files in KB. log_temp_files parameter controls logging temporary file names and sizes. </font>" >> $html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Temporary Space Read Queries: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "SET statement_timeout='60s' ; SET idle_in_transaction_session_timeout='60s';
$SQL21
"|sed '$d'|sed '$d'` "   >>$html
echo "<font face="verdana" color="#0099cc">Note: Run EXPLAIN plan on the top 10 temporary space read queries.</font>" >> $html

else
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">Postgres extension <a href="https://www.postgresql.org/docs/current/pgstatstatements.html" target="_blank">pg_stat_statements</a> is not installed. Installation of this extension is recommended. </font>" >>$html
echo "<br>" >> $html
fi

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#0099cc">Note: While modifying any database configuration, parameters, please consult/review with your DBA/DB expert. Results may vary depending on the workloads and expectations. Also, before applying modifications, learn about them at <a href="https://www.postgresql.org/docs/current/pgstatstatements.html" target="_blank">PostgreSQL official docs</a>. Before making any changes in production, its recommended to test those in testing environment thoroughly." >> $html

echo "<br>" >> $html
echo "<font face="verdana" color="#d3d3d3"><small>End of report. Script version V23</small></font>" >> $html
echo "<br>" >> $html

echo "</td></tr></table></body></html>" >> $html

sleep 1
echo "Report `pwd`/$html created!"


