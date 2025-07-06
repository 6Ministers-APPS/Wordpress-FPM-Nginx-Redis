// WP Limits
define( 'WP_MEMORY_LIMIT', '128M' );
define( 'WP_MAX_MEMORY_LIMIT', '256M' );

// Beget S3 Configuration
define('FLUENT_COMMUNITY_CLOUD_STORAGE_ENDPOINT', 's3.ru1.storage.beget.cloud');
define('FLUENT_COMMUNITY_CLOUD_STORAGE', 'amazon_s3');
define('FLUENT_COMMUNITY_CLOUD_STORAGE_REGION', ''); // change with your region. If it's global just remove this line or keep it empty
define('FLUENT_COMMUNITY_CLOUD_STORAGE_ACCESS_KEY', '5IED61S119ZYU66G7K5H');
define('FLUENT_COMMUNITY_CLOUD_STORAGE_SECRET_KEY', '1ZFQCrScXchkSbfHAOLTTVKqcrwEQcgXrDNQfbKZ');
define('FLUENT_COMMUNITY_CLOUD_STORAGE_BUCKET', '00d7173b4994-sovershenstvo'); // change with your bucket name
define('FLUENT_COMMUNITY_CLOUD_STORAGE_SUB_FOLDER', ''); // optional. If you want to store the files in a subfolder of that bucket

// REDIS
define( 'WP_REDIS_HOST', 'redis' );
define( 'WP_REDIS_PORT', 6379 );
// reasonable connection and read+write timeouts
define( 'WP_REDIS_TIMEOUT', 1 );
define( 'WP_REDIS_READ_TIMEOUT', 1 );

