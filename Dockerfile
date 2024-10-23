FROM nginx
# FROM nginxinc/nginx-unprivileged
COPY site /www/

COPY docs.conf /etc/nginx/conf.d/docs.conf
COPY .htpasswd /etc/nginx/.htpasswd

