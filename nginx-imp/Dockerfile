FROM openresty/openresty:1.25.3.2-alpine

RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY conf.d/default.conf /etc/nginx/conf.d/default.conf
COPY lua/ /etc/nginx/lua/

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
