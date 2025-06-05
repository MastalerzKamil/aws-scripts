#!/bin/bash

# Replace these with your actual values
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

echo "🌐 Configuring Nginx reverse proxy for Grafana..."
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

echo "🔒 Requesting SSL certificate from Let's Encrypt..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "✅ Testing renewal logic..."
certbot renew --dry-run

echo "📆 Setting up auto-renewal every 2 months (1st day @ 3AM)..."
tee /etc/cron.d/certbot-bimonthly > /dev/null <<EOF
0 3 1 */2 * root certbot renew --quiet --post-hook "systemctl reload nginx"
EOF
chmod 644 /etc/cron.d/certbot-bimonthly

echo "🎉 Setup complete! Access your Grafana at: https://$DOMAIN"