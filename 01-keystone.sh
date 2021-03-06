#!/bin/bash

source os.conf
source admin-openrc

##### Keystone Identity Service #####
mysql -u root -p$PASSWORD -e "SHOW DATABASES;" | grep keystone > /dev/null 2>&1 && echo "keystone database already exists" || mysql -u root -p$PASSWORD -e "CREATE DATABASE keystone; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$PASSWORD'; GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$PASSWORD';"

echo -n "installing packages... " && zypper -n in --no-recommends openstack-keystone apache2-mod_wsgi > /dev/null 2>&1 && echo "done"

[ ! -f /etc/keystone/keystone.conf.orig ] && cp -v /etc/keystone/keystone.conf /etc/keystone/keystone.conf.orig
cat << _EOF_ > /etc/keystone/keystone.conf
[DEFAULT]
verbose = True
log_dir = /var/log/keystone

[catalog]
driver = sql

[database]
connection = mysql+pymysql://keystone:$PASSWORD@$HOSTNAME/keystone

[signing]
cert_subject = /C=US/ST=Unset/L=Unset/O=Unset/CN=$HOSTNAME

[token]
provider = fernet
_EOF_

su -s /bin/sh -c "keystone-manage db_sync" keystone
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password $PASSWORD --bootstrap-admin-url http://$HOSTNAME:35357/v3/ --bootstrap-internal-url http://$HOSTNAME:35357/v3/ --bootstrap-public-url http://$HOSTNAME:5000/v3/ --bootstrap-region-id RegionOne

[ ! -f /etc/sysconfig/apache2.orig ] && cp -v /etc/sysconfig/apache2 /etc/sysconfig/apache2.orig
grep '^APACHE_SERVERNAME=""$' /etc/sysconfig/apache2 > /dev/null 2>&1
if [ $? -eq 0 ]
  then
    sed -i 's/APACHE_SERVERNAME=""/#APACHE_SERVERNAME=""/g' /etc/sysconfig/apache2
    cat << _EOF_ >> /etc/sysconfig/apache2
APACHE_SERVERNAME="$HOSTNAME"
_EOF_
fi

if [ ! -f /etc/apache2/conf.d/wsgi-keystone.conf ]
  then
    cat << _EOF_ >> /etc/apache2/conf.d/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        Require all granted
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    ErrorLogFormat "%{cu}t %M"
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        Require all granted
    </Directory>
</VirtualHost>
_EOF_
fi

chown -R keystone:keystone /etc/keystone
systemctl enable apache2.service
systemctl restart apache2.service
systemctl status apache2.service

openstack project list | grep service > /dev/null 2>&1 && echo "service project already exist" || openstack project create --domain default --description "Service Project" service
openstack project list

[ ! -f /etc/keystone/keystone-paste.ini.orig ] && cp -v /etc/keystone/keystone-paste.ini /etc/keystone/keystone-paste.ini.orig
sed -i 's/pipeline = cors sizelimit http_proxy_to_wsgi osprofiler url_normalize request_id admin_token_auth build_auth_context token_auth json_body ec2_extension public_service/pipeline = cors sizelimit http_proxy_to_wsgi osprofiler url_normalize request_id build_auth_context token_auth json_body ec2_extension public_service/g' /etc/keystone/keystone-paste.ini
sed -i 's/pipeline = cors sizelimit http_proxy_to_wsgi osprofiler url_normalize request_id admin_token_auth build_auth_context token_auth json_body ec2_extension s3_extension admin_service/pipeline = cors sizelimit http_proxy_to_wsgi osprofiler url_normalize request_id build_auth_context token_auth json_body ec2_extension s3_extension admin_service/g' /etc/keystone/keystone-paste.ini
sed -i 's/pipeline = cors sizelimit http_proxy_to_wsgi osprofiler url_normalize request_id admin_token_auth build_auth_context token_auth json_body ec2_extension_v3 s3_extension service_v3/pipeline = cors sizelimit http_proxy_to_wsgi osprofiler url_normalize request_id build_auth_context token_auth json_body ec2_extension_v3 s3_extension service_v3/g' /etc/keystone/keystone-paste.ini

openstack token issue
