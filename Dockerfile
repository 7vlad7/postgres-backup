FROM postgres:17-alpine

RUN apk add --no-cache aws-cli gnupg tzdata

COPY pgbackup.sh /usr/local/bin/pgbackup
RUN chmod +x /usr/local/bin/pgbackup

# postgres user: pg tools run unprivileged
USER postgres
ENTRYPOINT ["/usr/local/bin/pgbackup"]
CMD ["run"]
