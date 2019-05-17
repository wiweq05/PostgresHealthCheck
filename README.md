# PostgresHealthCheck
1.	Copy script on EC2 Linux instance with AWS CLI configured, psql installed and have AWS CLI configured with access to RDS/Aurora Postgres instance
2.	Make script executable: chmod +x pg_health_check.sh
3.	Run the file: ./ pg_health_check 
example: 
[ec2-user@ip-pgrpt]$ chmod +x pg_health_check.sh
[ec2-user@ip-pgrpt]$ ./ pg_health_check.sh
4.	It will take around 2-3 mins to run (depending on size of instance), and generate html report named <instance-name>_report.html

