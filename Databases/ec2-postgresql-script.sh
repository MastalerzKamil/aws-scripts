#!/bin/bash
set -xe

# --- CONFIGURATION ---
SECRET_NAME="secret store name"
AWS_REGION="eu-west-1"

# --- SYSTEM PREP ---
dnf install -y postgresql15-server postgresql15 awscli jq

# --- FETCH SECRETS ---
SECRET_JSON=$(aws secretsmanager get-secret-value --region $AWS_REGION --secret-id $SECRET_NAME --query SecretString --output text)

PG_DBNAME=$(echo $SECRET_JSON | jq -r .PG_DBNAME)
PG_USERNAME=$(echo $SECRET_JSON | jq -r .PG_USERNAME)
PG_PASSWORD=$(echo $SECRET_JSON | jq -r .PG_PASSWORD)
PG_PORT=$(echo $SECRET_JSON | jq -r .PG_PORT)

# --- INIT DB ---
if [ ! -d /var/lib/pgsql/data/base ]; then
  /usr/bin/postgresql-setup --initdb
fi

# --- CONFIGURE POSTGRESQL ---
CONF_FILE="/var/lib/pgsql/data/postgresql.conf"
sed -i "s/^#listen_addresses = .*/listen_addresses = '*'/" "$CONF_FILE"
sed -i "s/^#port = .*/port = $PG_PORT/" "$CONF_FILE"

# --- ALLOW REMOTE ACCESS ---
echo "host    all             all             0.0.0.0/0               md5" >> /var/lib/pgsql/data/pg_hba.conf

# --- START POSTGRESQL ---
systemctl enable postgresql
systemctl restart postgresql

sleep 5

# --- CREATE USER AND DB ---
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USERNAME') THEN
      CREATE USER "$PG_USERNAME" WITH PASSWORD '$PG_PASSWORD';
   END IF;
END
\$\$;
EOF

sudo -u postgres psql -c "CREATE DATABASE \"$PG_DBNAME\" OWNER \"$PG_USERNAME\";" 2>/dev/null || echo "Database $PG_DBNAME may already exist."
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$PG_DBNAME\" TO \"$PG_USERNAME\";"

echo "PostgreSQL setup complete. Ready for remote connections on port $PG_PORT."