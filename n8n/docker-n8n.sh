#!/bin/bash
set -e

# Update and install dependencies
dnf update -y
dnf install -y docker jq aws-cli nginx python3-certbot-nginx git

# Enable and start services
systemctl enable --now docker
systemctl enable --now nginx

# Add ec2-user to Docker group
usermod -aG docker ec2-user

export SECRECT_MANAGER_REGION="aws region"
export SECRET_NAME="secret store name"

# Fetch secrets
SECRET_JSON=$(aws secretsmanager get-secret-value --region $SECRET_MANAGER_REGION --secret-id $SECRET_NAME --query SecretString --output text)

# Parse PostgreSQL config
export PG_HOST=$(echo "$SECRET_JSON" | jq -r .PG_HOST)
export PG_PORT=$(echo "$SECRET_JSON" | jq -r .PG_PORT)
export PG_DATABASE=$(echo "$SECRET_JSON" | jq -r .PG_DBNAME)
export PG_USER=$(echo "$SECRET_JSON" | jq -r .PG_USERNAME)
export PG_PASSWORD=$(echo "$SECRET_JSON" | jq -r .PG_PASSWORD)

# Parse n8n & SSL config
export N8N_USERNAME=$(echo "$SECRET_JSON" | jq -r .N8N_USERNAME)
export N8N_PASSWORD=$(echo "$SECRET_JSON" | jq -r .N8N_PASSWORD)
export N8N_DOMAIN=$(echo "$SECRET_JSON" | jq -r .N8N_DOMAIN)
export CERT_EMAIL=$(echo "$SECRET_JSON" | jq -r .CERT_EMAIL)

# Build ARM-compatible n8n image
mkdir -p /opt/n8n && cd /opt/n8n
cat > Dockerfile <<'EOF'
FROM node:18-alpine
RUN apk add --no-cache python3 make g++ curl bash
RUN npm install -g n8n
CMD ["n8n"]
EOF

docker build -t custom-n8n-arm .

# Run n8n container
docker run -d \
  --name n8n \
  -p 127.0.0.1:5678:5678 \
  -v n8n_data:/home/node/.n8n \
  --restart always \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=$PG_HOST \
  -e DB_POSTGRESDB_PORT=$PG_PORT \
  -e DB_POSTGRESDB_DATABASE=$PG_DATABASE \
  -e DB_POSTGRESDB_USER=$PG_USER \
  -e DB_POSTGRESDB_PASSWORD=$PG_PASSWORD \
  -e N8N_BASIC_AUTH_ACTIVE=true \
  -e N8N_BASIC_AUTH_USER=$N8N_USERNAME \
  -e N8N_BASIC_AUTH_PASSWORD=$N8N_PASSWORD \
  -e N8N_HOST=$N8N_DOMAIN \
  -e WEBHOOK_TUNNEL_URL=https://$N8N_DOMAIN \
  -e GENERIC_TIMEZONE=Europe/Warsaw \
  -e N8N_RUNNERS_ENABLED=true \
  custom-n8n-arm

# Create NGINX reverse proxy config
cat > /etc/nginx/conf.d/n8n.conf <<EOF
server {
    listen 80;
    server_name $N8N_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Reload nginx
nginx -t && systemctl reload nginx

# Request SSL certificate
certbot --nginx --non-interactive --agree-tos --redirect --email $CERT_EMAIL -d $N8N_DOMAIN

# Cron: renew SSL every 60 days (2nd month only)
cat > /etc/cron.monthly/certbot-renew-n8n <<'EOF'
#!/bin/bash
# Run only if current month is even (Feb, Apr, Jun...)
if [ $((10#$(date +%m) % 2)) -eq 0 ]; then
  /usr/bin/certbot renew --quiet --post-hook "docker restart n8n && systemctl reload nginx"
fi
EOF

chmod +x /etc/cron.monthly/certbot-renew-n8n