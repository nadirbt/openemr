FROM openemr/openemr:8.0.0
WORKDIR /var/www/localhost/htdocs/openemr
COPY --chown=apache:apache . .
