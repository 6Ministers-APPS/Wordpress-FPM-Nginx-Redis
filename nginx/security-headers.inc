# Подключается через include из server и из location с собственными add_header
# (add_header в location сбрасывает унаследованные). Расширение .inc — чтобы
# conf.d/*.conf не подхватывал файл на уровне http.
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
