#!/bin/bash

# CONFIGURE YOUR DOMAIN AND EMAIL HERE
DOMAIN="domain.com"
EMAIL="your@email.com"

echo "🔧 Updating system and installing base packages..."
dnf update -y
dnf install -y nginx wget curl policycoreutils-python-utils git mysql epel-release

echo "📦 Installing Certbot (EPEL version)..."
dnf install -y certbot python3-certbot-nginx

echo "📦 Installing Grafana OSS..."
cat <<EOF > /etc/yum.repos.d/grafana.repo
[grafana]
name=Grafana OSS
baseurl=https://packages.grafana.com/oss/rpm
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://packages.grafana.com/gpg.key
EOF

dnf install -y grafana
systemctl enable --now grafana-server

echo "🌐 Setting up Nginx reverse proxy for Grafana..."
tee /etc/nginx/conf.d/grafana.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:3000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

systemctl enable --now nginx
nginx -t && systemctl reload nginx

echo "🔒 Issuing SSL certificate with Let's Encrypt..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "✅ Testing renewal..."
certbot renew --dry-run

echo "✅ Done! Grafana is now live at: https://$DOMAIN"