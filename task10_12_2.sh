#!/bin/bash

CUR_PWD="$( cd "$(dirname "$0")"; pwd -P )"
CONFIG_FILE="${CUR_PWD}/config"

echo CUR_PWD=${CUR_PWD}


EXTERNAL_IP=$(grep EXTERNAL_IP ${CONFIG_FILE} | awk -F= '{print $2}')
HOST_NAME=$(grep HOST_NAME ${CONFIG_FILE} | awk -F= '{print $2}')
NGINX_IMAGE=$(grep NGINX_IMAGE ${CONFIG_FILE} | awk -F= '{print $2}' | sed 's/"//g')
APACHE_IMAGE=$(grep APACHE_IMAGE ${CONFIG_FILE} | awk -F= '{print $2}' | sed 's/"//g')
NGINX_PORT=$(grep NGINX_PORT ${CONFIG_FILE} | awk -F= '{print $2}')
NGINX_LOG_DIR=$(grep NGINX_LOG_DIR ${CONFIG_FILE} | awk -F= '{print $2}')

echo EXTERNAL_IP=${EXTERNAL_IP}
echo HOST_NAME=${HOST_NAME}
echo NGINX_IMAGE=${NGINX_IMAGE}
echo APACHE_IMAGE=${APACHE_IMAGE}
echo NGINX_PORT=${NGINX_PORT}
echo NGINX_LOG_DIR=${NGINX_LOG_DIR}
echo ""

[ -d ${CUR_PWD}/certs ] || mkdir -p  ${CUR_PWD}/certs
[ -d ${CUR_PWD}/etc ] || mkdir -p ${CUR_PWD}/etc
[ -d ${NGINX_LOG_DIR} ] || mkdir -p ${NGINX_LOG_DIR}

echo "Installation openssl and iptables"
apt-get update > /dev/null && apt-get install openssl iptables -y > /dev/null
echo ""

sslfunction () {
echo "Creating Root-certificate"
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 -keyout ${CUR_PWD}/root.key -out ${CUR_PWD}/certs/root.crt -subj '/C=UA/ST=Kievskaya/L=Kiev/O=IT/OU=IT-Department/CN=ROOT-CA' -sha256 > /dev/null
echo ""

echo "Create CSR for web-site"
cat > ${CUR_PWD}/openssl.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = v3_req
distinguished_name = req_distinguished_name

[ req_distinguished_name ]
C=UA
ST=Kharkov
L=Kharkov
O=IT
OU=IT-Department
emailAddress=myname@mydomain.com
CN = ${HOST_NAME}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${HOST_NAME}
IP.1 = ${EXTERNAL_IP}
EOF
echo ""

echo "Create Private key for web-site"
openssl genrsa -out ${CUR_PWD}/certs/web.key 2048 > /dev/null
echo ""

echo "Create CSR for web-site"
openssl req -new -key ${CUR_PWD}/certs/web.key -out ${CUR_PWD}/certs/web.csr -config ${CUR_PWD}/openssl.cnf >/dev/null
echo ""

echo "Create and sign web-certificate by rootCA"
openssl x509 -req -days 730 -in ${CUR_PWD}/certs/web.csr -CA ${CUR_PWD}/certs/root.crt -CAkey ${CUR_PWD}/root.key -CAcreateserial -out ${CUR_PWD}/certs/web.crt -extfile ${CUR_PWD}/openssl.cnf -extensions v3_req > /dev/null
echo ""

echo "Create web fullchain certificate"
cat  ${CUR_PWD}/certs/web.crt ${CUR_PWD}/certs/root.crt > ${CUR_PWD}/certs/fullchain.crt
echo ""
}

sslfunction

echo "Check md5-sum for root certifiacte and private key"
openssl x509 -noout -modulus -in ${CUR_PWD}/certs/root.crt | openssl md5
openssl rsa -noout -modulus -in ${CUR_PWD}/root.key | openssl md5
echo ""

echo "Check md5-sum for domain certifiacte and private key"
openssl x509 -noout -modulus -in ${CUR_PWD}/certs/web.crt | openssl md5
openssl rsa -noout -modulus -in ${CUR_PWD}/certs/web.key | openssl md5
echo ""

echo "Check domain certificate"
openssl x509 -text -noout -in ${CUR_PWD}/certs/web.crt | grep -EA1 'Issuer|Subject|Subject Alternative Name'
echo ""


echo "Creating nginx.conf"
cat << 'EOF' > ${CUR_PWD}/etc/nginx.conf
user  nginx;
worker_processes  1;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events {
    worker_connections  1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    tcp_nopush     on;
    keepalive_timeout  65;
    gzip  on;
    include /etc/nginx/conf.d/*.conf;
}
EOF
echo ""

echo "Creating ssl.conf"
cat << EOF > ${CUR_PWD}/etc/ssl.conf
        ssl_session_cache shared:SSL:50m;
        ssl_session_timeout 1d;
        ssl_prefer_server_ciphers       on;
        ssl_protocols  TLSv1.2;
        ssl_ciphers   ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:ECDH+3DES:DH+3DES:RSA+AESGCM:RSA+AES:RSA+3DES:!aNULL:!MD5:!DSS;
        #ssl_ecdh_curve secp521r1;
        ssl_session_tickets off;
        ssl_buffer_size 8k;
EOF
echo ""

echo "Creating proxy.conf"
cat << EOF > ${CUR_PWD}/etc/proxy.conf
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_buffer_size 128k;
        proxy_buffers 256 16k;
        proxy_busy_buffers_size 256k;
        proxy_temp_file_write_size 256k;

        proxy_connect_timeout 90;
        proxy_send_timeout 90;
        proxy_read_timeout 90;
EOF
echo ""

echo "Creating default.conf"
cat << EOF >  ${CUR_PWD}/etc/default.conf

server {
    listen      ${NGINX_PORT} default_server;
    server_name  ${HOST_NAME};

    ssl on;
    ssl_certificate /etc/nginx/certs/fullchain.crt;
    ssl_certificate_key /etc/nginx/certs/web.key;
    include     /etc/nginx/ssl.conf;

    root   /usr/share/nginx/html;

    location / {
        proxy_pass http://apache:80;
        include /etc/nginx/proxy.conf;
        }
   }
EOF
echo ""

echo "Installation docker-ce and docker-compose..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install docker-ce docker-compose -y
echo ""

echo "Creating docker-compose.yml..."
cat << EOF > ${CUR_PWD}/docker-compose.yml
version: '2'
services:
 nginx:
  image: ${NGINX_IMAGE}
  volumes:
   - ${CUR_PWD}/certs:/etc/nginx/certs
   - ${CUR_PWD}/etc/nginx.conf:/etc/nginx/nginx.conf
   - ${CUR_PWD}/etc/proxy.conf:/etc/nginx/proxy.conf
   - ${CUR_PWD}/etc/ssl.conf:/etc/nginx/ssl.conf
   - ${CUR_PWD}/etc/default.conf:/etc/nginx/conf.d/default.conf
   - ${NGINX_LOG_DIR}:/var/log/nginx
  ports:
   - "${NGINX_PORT}:${NGINX_PORT}"
  depends_on:
   - apache
 apache:
   image: ${APACHE_IMAGE}
EOF
echo ""

echo "Starting docker-containers via docker-compose..."
docker-compose -f ${CUR_PWD}/docker-compose.yml up -d
echo ""

