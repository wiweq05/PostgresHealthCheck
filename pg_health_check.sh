#!/bin/bash
clear
echo -n -e  "RDS Postgres Instance Name: "
read RDSNAME
echo -n -e "RDS Postgres Endpoint URL: "
read EP
echo -n -e "Database Name: "
read DBNAME
echo -n -e "RDS master user name: "
read MASTERUSER
echo -n -e "Password: "
read MYPASS
echo -n -e "Company Name: "
read COMNAME

#SQLs Used In the Script:

#Idele Connections 
SQL1="select count(*) from pg_stat_activity where state='idle';"

#Size of all databases
SQL2="SELECT pg_database.datname,
pg_database_size(pg_database.datname) as "DB_Size",
pg_size_pretty(pg_database_size(pg_database.datname)) as "Pretty_DB_size"
 FROM pg_database ORDER by 2 DESC;"
 
#Size only of all databases 
SQL3="SELECT pg_database_size(pg_database.datname)  FROM pg_database"

#Top 10 biggest tables 
SQL4="Select schemaname as table_schema,
     relname as table_name,
     pg_size_pretty(pg_total_relation_size(relid)) as "Total_Size",
     pg_size_pretty(pg_relation_size(relid)) as "Data_Size",
     pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid))
       as "Index_Size"
 from pg_catalog.pg_statio_user_tables
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
ORDER BY SUM(pg_relation_size(idx)) DESC;"

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
ORDER BY pg_relation_size(s.indexrelid) DESC limit 15;" 

#Database Age 
SQL7="select datname, ltrim(to_char(age(datfrozenxid), '999,999,999,999,999')) age from pg_database where datname not like 'rdsadmin';"

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
SQL9="SELECT
schemaname, relname,last_vacuum, cast(last_autovacuum as date), cast(last_analyze as date), cast(last_autoanalyze as date), 
pg_size_pretty(pg_total_relation_size(table_name)) as table_total_size 
from pg_stat_user_tables a, information_schema.tables b where a.relname=b.table_name ORDER BY pg_total_relation_size(table_name) DESC limit 10;"

#Memory Parameters 
SQL10="select name, setting, source, context from pg_settings where name like '%mem%' or name ilike '%buff%'; "

#Performance Parameters 
SQL11="select name, setting from pg_settings where name IN ('shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'default_statistics_target', 'random_page_cost', 'rds.logical_replication','wal_keep_segments');"

html=${RDSNAME}_report.html
#Generating HTML file
echo "<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">" > $html
echo "<html>" >> $html
echo "<link rel="stylesheet" href="https://unpkg.com/purecss@0.6.2/build/pure-min.css">" >> $html
echo "<body style="font-family:'Verdana'" bgcolor="#F8F8F8">" >> $html
echo "<fieldset>" >> $html
echo "<center>" >> $html
echo "<h1><font face="verdana" color="#0099cc"><u>Postgres Health Report For $COMNAME</u></font></h1>" >> $html
echo "</center>" >> $html
echo "<br>" >> $html
echo "<h3><font face="verdana">Postgres Specialist - Enterprise Support</h3></color>" >> $html
echo "<br>" >> $html
echo "<font face="verdana">Vivek Singh - `date +%m-%d-%Y`" >> $html

echo "</fieldset>" >> $html
echo "<br>" >> $html

echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Instance Details:  </font>" >>$html
echo "<br>" >> $html
echo "Postgres Instance Identifier: $RDSNAME" >> $html
echo "<br>" >> $html


PSQLCL="psql -h $EP  -p 5432 -U $MASTERUSER $DBNAME"
if [ "$?" -gt "0" ]; then
INSTSTAT=("Not Running")
exit
else

echo "Instance is running. Creating Report..."
fi
echo "Postgres Engine Version: " >>$html 
echo `PGPASSWORD=$MYPASS $PSQLCL -c "SELECT version()" | awk 'FNR== 3'  `  >>$html
echo "<br>" >> $html
echo "Maximum Connections :" >>$html
echo  `PGPASSWORD=$MYPASS $PSQLCL -c "show max_connections" | awk 'FNR== 3'`  >>$html
echo "<br>" >> $html
echo "Curent Active Connections: " >>$html
echo `PGPASSWORD=$MYPASS $PSQLCL -c "select count(*) from pg_stat_activity;" | awk 'FNR== 3'`  >>$html
echo "<br>" >> $html
echo "Idle Connections : `PGPASSWORD=$MYPASS $PSQLCL -c "$SQL1" | awk 'FNR== 3'` " >>$html
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Instance Configuration: </font>" >>$html
aws rds describe-db-instances --db-instance-identifier $RDSNAME | grep 'Allocated\|Public\|MonitoringInterval\|MultiAZ\|\StorageType\|\BackupRetentionPeriod\|DBInstanceClass'|sed "s/\"//g"|sed "s/\,//g"| sed "s/\PubliclyAccessible/<br>Publicly Accessible/g"| sed "s/\MonitoringInterval/<br>EM Monitoring Interval/g" | sed "s/\MultiAZ/<br>Multi AZ Enabled?/g" | sed "s/\AllocatedStorage/<br>Allocated Storage (GB)/g" |  sed "s/\DBInstanceClass/<br>DB Instance Class/g" | sed "s/\BackupRetentionPeriod/<br>Backup Retention Period/g" | sed "s/\StorageType/<br>Storage Type/g" |  sed "s/\ B//g"|sed "s/\gp2/GP2/g" >>$html 
echo "<br>" >> $html
echo "<br>" >> $html

echo "<font face="verdana" color="#ff6600">Size of all Databases: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL2
"|sed '$d'|sed '$d' ` " >>$html
echo "<br>" >> $html
#Total Log Size
TLS=`aws rds describe-db-log-files --db-instance-identifier $RDSNAME | grep "Size" | grep -o '[0-9]*' | awk '{n += $1}; END{print n}'`
AGB=1073741824
echo "<font face="verdana" color="#ff6600">Total Size of Log Files:  </font>" >>$html
echo $TLS | sed 's/$/ Bytes/' >>$html
echo "<br>" >> $html
echo $((ERT / AGB)) | sed 's/$/ GB/' >>$html
echo "<br>" >> $html
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Total Size of ALL Databases:  </font>" >>$html
PGPASSWORD=$MYPASS $PSQLCL -c "$SQL3" |  sed '$d' | sed '$d'| tail -n +3 > ret.txt
ADB=`awk '{ sum += $1 } END { print sum }' ret.txt`
rm ret.txt
echo $ADB  | sed 's/$/ Bytes/' >>$html
echo "<br>" >> $html
echo $((ADB / AGB)) | sed 's/$/ GB/' >>$html


echo "<br>" >> $html
echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Biggest Tables: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
 $SQL4 
"|sed '$d'|sed '$d' ` " >>$html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Duplicate Indexes: </font>" >>$html
echo "<br>" >> $html


echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL5 
"|sed '$d'|sed '$d' ` " >>$html


echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Unused Indexes: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL6 
"|sed '$d'|sed '$d' ` " >>$html


echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Database Age: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL7 
"|sed '$d'|sed '$d' ` " >>$html


echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Most Bloated Tables: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL8 
"|sed '$d'|sed '$d' ` " >>$html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Top 10 Biggest Tables Last Vacuumed: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL9
"|sed '$d'|sed '$d'` "   >>$html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Vacuum Parameters: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
select name, setting, source, context from pg_settings where name like 'autovacuum%'
"|sed '$d'|sed '$d'` "   >>$html


echo "<br>" >> $html
echo "<br>" >> $html
echo "<font face="verdana" color="#ff6600">Memory Parameters: </font>" >>$html
echo "<br>" >> $html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL10
"|sed '$d'|sed '$d' ` "   >>$html
echo "<br>" >> $html
echo "<br>" >> $html

echo "<font face="verdana" color="#ff6600">Performance Parameters: </font>" >>$html
echo "`PGPASSWORD=$MYPASS $PSQLCL --html -c "
$SQL11
"|sed '$d'|sed '$d' ` "   >>$html

echo "<br>" >> $html
echo "<br>" >> $html
echo "<br>" >> $html
sleep 1
echo "Done."



