# Общая часть location для PHP (подключается из nginx.conf: обычные .php и /wp-admin/)
try_files $uri =404;
fastcgi_split_path_info ^(.+\.php)(/.+)$;

fastcgi_pass unix:/var/run/php/php-fpm.sock;
fastcgi_index index.php;
include fastcgi_params;

fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_param HTTP_HOST $host;
fastcgi_param REQUEST_SCHEME $scheme;
fastcgi_param HTTPS on; 

# КЭШ
fastcgi_cache WORDPRESS;
# Страницы чистит Nginx Helper при правке контента, поэтому TTL длинный
fastcgi_cache_valid 200 301 302 12h;
fastcgi_cache_valid 404 1m;
fastcgi_cache_bypass $do_skip_cache;
fastcgi_no_cache $do_skip_cache;

add_header X-FastCGI-Cache $upstream_cache_status;

# Буферы
fastcgi_buffer_size 128k;
fastcgi_busy_buffers_size 256k;
fastcgi_buffers 4 256k;

# Проброс IP
fastcgi_param HTTP_X_REAL_IP $remote_addr;
# XFF уже содержит клиента (real_ip_recursive), $proxy_add_x_forwarded_for дублировал бы его
fastcgi_param HTTP_X_FORWARDED_FOR $http_x_forwarded_for;
fastcgi_param HTTP_X_FORWARDED_PROTO $scheme;

# Брутфорс wp-login.php (ключ пустой для остальных запросов — они не лимитируются)
limit_req zone=wplogin burst=5 nodelay;
limit_req_status 429;

include /etc/nginx/conf.d/security-headers.inc;
