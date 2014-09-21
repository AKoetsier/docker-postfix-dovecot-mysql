# Postfix + Dovecot + MySQL docker image
#
# Build based on http://oskarhane.com/setup-your-own-mail-hosting-with-linux-postfix-dovecot-and-mysql/

FROM ubuntu:14.04
MAINTAINER Guillaume Hain zedtux@zedroot.org

ENV MYSQL_USERNAME mail_admin
ENV MYSQL_PASSWORD "i3fY9o0Pq2@zD"
ENV MYSQL_DBNAME   mail

RUN apt-get update && \
  apt-get upgrade -y && \
  apt-get install -y postfix \
    postfix-mysql \
    mysql-client \
    mysql-server \
    dovecot-common \
    dovecot-imapd \
    libsasl2-2 \
    libsasl2-modules \
    libsasl2-modules-sql \
    sasl2-bin \
    libpam-mysql \
    openssl \
    mailutils \
    supervisor

ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN service mysql start && \
  mysql -u root -e 'CREATE DATABASE '$MYSQL_DBNAME'; \
    USE '$MYSQL_DBNAME'; \
    GRANT SELECT, INSERT, UPDATE, DELETE ON '$MYSQL_DBNAME'.* TO '$MYSQL_USERNAME'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD'; \
    GRANT SELECT, INSERT, UPDATE, DELETE ON '$MYSQL_DBNAME'.* TO '$MYSQL_USERNAME'@'localhost.localdomain' IDENTIFIED BY '$MYSQL_PASSWORD'; \
    FLUSH PRIVILEGES; \
    CREATE TABLE domains (DOMAIN VARCHAR(50) NOT NULL, PRIMARY KEY (DOMAIN)); \
    CREATE TABLE forwardings (SOURCE VARCHAR(80) NOT NULL, destination TEXT NOT NULL, PRIMARY KEY (SOURCE)); \
    CREATE TABLE users (email VARCHAR(80) NOT NULL, password VARCHAR(20) NOT NULL, PRIMARY KEY (email)); \
    CREATE TABLE transport (DOMAIN VARCHAR(128) NOT NULL, transport VARCHAR(128) NOT NULL, UNIQUE KEY DOMAIN (DOMAIN));'

ADD cf_files/mysql-virtual_domains.cf /etc/postfix/
ADD cf_files/mysql-virtual_forwardings.cf /etc/postfix/
ADD cf_files/mysql-virtual_mailboxes.cf /etc/postfix/
ADD cf_files/mysql-virtual_email2email.cf /etc/postfix/

RUN chmod o= /etc/postfix/mysql-virtual_*.cf && \
  chgrp postfix /etc/postfix/mysql-virtual_*.cf && \
  groupadd -g 5000 vmail && \
  useradd -g vmail -u 5000 vmail -d /home/vmail -m

RUN postconf -e 'myhostname = server.example.com' && \
  postconf -e 'mydestination = server.example.com, localhost, localhost.localdomain' && \
  postconf -e 'mynetworks = 127.0.0.0/8' && \
  postconf -e 'message_size_limit = 30720000' && \
  postconf -e 'virtual_alias_domains =' && \
  postconf -e 'virtual_alias_maps = proxy:mysql:/etc/postfix/mysql-virtual_forwardings.cf, mysql:/etc/postfix/mysql-virtual_email2email.cf' && \
  postconf -e 'virtual_mailbox_domains = proxy:mysql:/etc/postfix/mysql-virtual_domains.cf' && \
  postconf -e 'virtual_mailbox_maps = proxy:mysql:/etc/postfix/mysql-virtual_mailboxes.cf' && \
  postconf -e 'virtual_mailbox_base = /home/vmail' && \
  postconf -e 'virtual_uid_maps = static:5000' && \
  postconf -e 'virtual_gid_maps = static:5000' && \
  postconf -e 'smtpd_sasl_auth_enable = yes' && \
  postconf -e 'broken_sasl_auth_clients = yes' && \
  postconf -e 'smtpd_sasl_authenticated_header = yes' && \
  postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination' && \
  postconf -e 'smtpd_use_tls = yes' && \
  postconf -e 'smtpd_tls_cert_file = /etc/postfix/smtpd.cert' && \
  postconf -e 'smtpd_tls_key_file = /etc/postfix/smtpd.key' && \
  postconf -e 'virtual_create_maildirsize = yes' && \
  postconf -e 'virtual_maildir_extended = yes' && \
  postconf -e 'proxy_read_maps = $local_recipient_maps $mydestination $virtual_alias_maps $virtual_alias_domains $virtual_mailbox_maps $virtual_mailbox_domains $relay_recipient_maps $relay_domains $canonical_maps $sender_canonical_maps $recipient_canonical_maps $relocated_maps $transport_maps $mynetworks $virtual_mailbox_limit_maps' && \
  postconf -e virtual_transport=dovecot && \
  postconf -e dovecot_destination_recipient_limit=1

WORKDIR /etc/postfix
RUN openssl req -new -outform PEM -out smtpd.cert -newkey rsa:2048 -nodes \
  -keyout smtpd.key -keyform PEM -days 365 -x509 \
  -subj "/C=LU/ST=Luxembourg/L=Luxembourg/O=ZedR00t.0rg/OU=IT Department/CN=example.com"
RUN chmod o= /etc/postfix/smtpd.key

RUN mkdir -p /var/spool/postfix/var/run/saslauthd
RUN cp -a /etc/default/saslauthd /etc/default/saslauthd.bak

RUN sed -i 's/START=no/START=yes/' /etc/default/saslauthd
RUN sed -i 's#OPTIONS=".*"#OPTIONS="-c -m /var/spool/postfix/var/run/saslauthd -r"#' /etc/default/saslauthd

ADD pam.d/smtp /etc/pam.d/
ADD sasl/smtpd.conf /etc/postfix/sasl/

RUN chmod o= /etc/pam.d/smtp && \
  chmod o= /etc/postfix/sasl/smtpd.conf && \
  adduser postfix sasl

RUN echo "dovecot   unix  -       n       n       -       -       pipe \
    flags=DRhu user=vmail:vmail argv=/usr/lib/dovecot/deliver -d ${recipient}" >> /etc/postfix/master.cf

ADD dovecot/dovecot.conf /etc/dovecot/

RUN sed -i 's/#driver =/driver = mysql/' /etc/dovecot/dovecot-sql.conf.ext
RUN sed -i 's/#connect =/connect = host=127.0.0.1 dbname='$MYSQL_DBNAME' user='$MYSQL_USERNAME' password='$MYSQL_PASSWORD'/' /etc/dovecot/dovecot-sql.conf.ext
RUN sed -i 's/#default_pass_scheme = MD5/default_pass_scheme = CRYPT/' /etc/dovecot/dovecot-sql.conf.ext
RUN sed -i 's/#password_query = \\/password_query = SELECT email as user, password FROM users WHERE email='%u';/' /etc/dovecot/dovecot-sql.conf.ext

RUN chgrp vmail /etc/dovecot/dovecot.conf && \
  chmod g+r /etc/dovecot/dovecot.conf

RUN service mysql start && \
  mysql -u root -e "USE mail; \
    INSERT INTO domains (domain) VALUES ('example.com'); \
    INSERT INTO users (email, password) VALUES ('mynewmail@example.com', ENCRYPT('password'));"

EXPOSE 25
EXPOSE 143
EXPOSE 993

CMD ["/usr/bin/supervisord"]
