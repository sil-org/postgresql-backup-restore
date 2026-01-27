#!/usr/bin/env sh

MYNAME="postgresql-backup-restore"

# hostname:port:database:username:password
echo ${DB_HOST}:*:*:${DB_USER}:${DB_USERPASSWORD}      > ~/.pgpass
echo ${DB_HOST}:*:*:${DB_ROOTUSER}:${DB_ROOTPASSWORD} >> ~/.pgpass
chmod 600 ~/.pgpass

STATUS=0

case "${MODE}" in
    backup|restore)
        /data/${MODE}.sh || STATUS=$?
        ;;
    *)
        echo ${MYNAME}: FATAL: Unknown MODE: ${MODE}
        exit 1
esac

if [ $STATUS -ne 0 ]; then
    echo ${MYNAME}: Non-zero exit: $STATUS
fi

exit $STATUS
