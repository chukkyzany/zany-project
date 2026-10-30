#!/bin/bash
# EC2 user data for the eshop app server (Ubuntu 22.04 / 24.04)
# Installs Apache + PHP + MySQL client and serves a placeholder page.

exec > >(tee /var/log/user-data.log) 2>&1
set -x

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y apache2 php libapache2-mod-php php-mysql mysql-client

systemctl enable --now apache2

# Make sure the SSM agent (Session Manager) is running; it ships with recent Ubuntu AMIs
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# Health check page for the load balancer target group
echo "OK" > /var/www/html/health.html

# Placeholder app page (replaced by the real e-commerce app later)
rm -f /var/www/html/index.html
cat > /var/www/html/index.php <<'EOF'
<?php
echo "<h1>eshop</h1>";
echo "<p>Served by: " . gethostname() . "</p>";
?>
EOF

chown -R www-data:www-data /var/www/html
systemctl restart apache2
