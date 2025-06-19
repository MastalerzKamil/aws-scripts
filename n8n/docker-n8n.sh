#!/bin/bash
set -e

# Fetch secrets from AWS Secrets Manager
REGION="eu-west-1"
SECRET_NAME="mydevil"
SECRETS=$(aws secretsmanager get-secret-value --region $REGION --secret-id $SECRET_NAME --query SecretString --output text)

# Parse secrets into variables
export N8N_DOMAIN=$(echo $SECRETS | jq -r '.N8N_DOMAIN')
export CERT_EMAIL=$(echo $SECRETS | jq -r '.CERT_EMAIL')
export PG_USERNAME=$(echo $SECRETS | jq -r '.PG_USERNAME')
export PG_PASSWORD=$(echo $SECRETS | jq -r '.PG_PASSWORD')
export PG_HOST=$(echo $SECRETS | jq -r '.PG_HOST')
export PG_PORT=$(echo $SECRETS | jq -r '.PG_PORT')
export PG_DATABASE=$(echo $SECRETS | jq -r '.PG_DATABASE')
export N8N_USERNAME=$(echo $SECRETS | jq -r '.N8N_USERNAME')
export N8N_PASSWORD=$(echo $SECRETS | jq -r '.N8N_PASSWORD')

# Install dependencies
dnf update -y
dnf install -y docker git nginx jq curl

# Start and enable Docker
systemctl enable --now docker

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create n8n Docker Compose config
mkdir -p /opt/n8n && cd /opt/n8n

cat <<EOF > docker-compose.yml
version: '3.8'
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${PG_HOST}
      - DB_POSTGRESDB_PORT=${PG_PORT}
      - DB_POSTGRESDB_DATABASE=${PG_DATABASE}
      - DB_POSTGRESDB_USER=${PG_USERNAME}
      - DB_POSTGRESDB_PASSWORD=${PG_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USERNAME}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASSWORD}
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - WEBHOOK_URL=https://${N8N_DOMAIN}/
      - N8N_EDITOR_BASE_URL=https://${N8N_DOMAIN}/
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
EOF

docker-compose up -d

# Install Certbot
dnf install -y epel-release
dnf install -y certbot python3-certbot-nginx

# Generate SSL cert
certbot --nginx --non-interactive --agree-tos --email ${CERT_EMAIL} -d ${N8N_DOMAIN}

# Nginx config
cat <<EOF > /etc/nginx/conf.d/n8n.conf
server {
    listen 80;
    server_name ${N8N_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${N8N_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${N8N_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${N8N_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
EOF

# Reload Nginx
systemctl enable --now nginx
nginx -t && systemctl reload nginx

# Setup SSL auto-renew
echo "0 3 * * * root certbot renew --post-hook 'systemctl reload nginx'" > /etc/cron.d/certbot-renew