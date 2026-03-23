[Unit]
Description=__SERVICE_NAME__
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=__RUN_USER__
Group=__RUN_GROUP__
WorkingDirectory=__APP_DIR__
EnvironmentFile=__ENV_FILE__
ExecStart=__START_SCRIPT__
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
StandardOutput=append:__LOG_FILE__
StandardError=append:__LOG_FILE__

[Install]
WantedBy=multi-user.target
