#!/bin/bash -x
set -e

EXCLUDE_OPT=
PASS_OPT=
export MYSQL_HOST=${MYSQL_HOST:=mysql}
export MYSQL_PORT=${MYSQL_PORT:=3306}
export MYSQL_USER=${MYSQL_USER:=<required>}
export MYSQL_PASS=${MYSQL_PASS:=<required>}

for i in "$@"; do
    case $i in
        --exclude=*)
        EXCLUDE_OPT="${i#*=}"
        shift
        ;;
        *)
            # unknown option
        ;;
    esac
done

if [ -n $MYSQL_PASS ]; then
    PASS_OPT="--password=${MYSQL_PASS}"
fi

if [ -n $EXCLUDE_OPT ]; then
    EXCLUDE_OPT="| grep -Ev (${EXCLUDE_OPT//,/|})"
fi

if [ "$1" == "backup" ]; then

    databases=`mysql --user=$MYSQL_USER --host=$MYSQL_HOST --port=$MYSQL_PORT ${PASS_OPT} -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema) ${EXCLUDE_OPT}"`

 
    for db in $databases; do
        echo "dumping $db"

        mysqldump --force --opt --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --databases $db ${PASS_OPT} | gzip > "/tmp/$db.gz"

        if [ $? == 0 ]; then
            aws s3 cp /tmp/$db.gz s3://$S3_BUCKET/$S3_PATH/$db.gz

            if [ $? == 0 ]; then
                rm /tmp/$db.gz
            else
                >&2 echo "couldn't transfer $db.gz to S3"
            fi
        else
            >&2 echo "couldn't dump $db"
        fi
    done
    
    # Send alive signal after successful backup
    if [ -n "$ALIVE_URL" ]; then
      wget --no-verbose --user $ALIVE_USERNAME --password $ALIVE_PASSWORD $ALIVE_URL -O /dev/null
    fi

elif [ "$1" == "restore" ]; then
    if [ -n "$2" ]; then
        archives=$2.gz
    else
        archives=`aws s3 ls s3://$S3_BUCKET/$S3_PATH/ | awk '{print $4}' ${EXCLUDE_OPT}`
    fi

    for archive in $archives; do
        tmp=/tmp/$archive

        echo "restoring $archive"
        echo "...transferring"

        aws s3 cp s3://$S3_BUCKET/$S3_PATH/$archive $tmp

        if [ $? == 0 ]; then
            echo "...restoring"
            db=`basename --suffix=.gz $archive`

            if [ -n $MYSQL_PASS ]; then
                yes | mysqladmin --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --password=$MYSQL_PASS drop $db

                mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --password=$MYSQL_PASS -e "CREATE DATABASE $db CHARACTER SET $RESTORE_DB_CHARSET COLLATE $RESTORE_DB_COLLATION"
                gunzip -c $tmp | mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER --password=$MYSQL_PASS $db
            else
                yes | mysqladmin --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER drop $db

                mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER -e "CREATE DATABASE $db CHARACTER SET $RESTORE_DB_CHARSET COLLATE $RESTORE_DB_COLLATION"
                gunzip -c $tmp | mysql --host=$MYSQL_HOST --port=$MYSQL_PORT --user=$MYSQL_USER $db
            fi
        else
            rm $tmp
        fi
    done
else
    >&2 echo "You must provide either backup or restore to run this container"
    exit 64
fi
