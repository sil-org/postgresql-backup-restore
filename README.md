# postgresql-backup-restore
Service to backup and/or restore a PostgreSQL database to/from S3

## How to use it
1. Create an S3 bucket to hold your backups
2. Turn versioning on for that bucket
3. Supply all appropriate environment variables
4. Run a backup and check your bucket for that backup

### Environment variables
`MODE` Valid values: `backup`, `restore`

`DB_HOST` hostname of the database server

`DB_NAME` name of the database

`DB_OPTIONS` optional arguments to supply to the backup or restore commands

`DB_ROOTPASSWORD` password for the `DB_ROOTUSER`

`DB_ROOTUSER` database administrative user, typically "postgres" for PostgreSQL databases

`DB_USERPASSWORD` password for the `DB_USER`

`DB_USER` user that accesses the database (PostgreSQL "role")

`AWS_ACCESS_KEY_ID` used for S3 interactions

`AWS_SECRET_ACCESS_KEY` used for S3 interactions

`AWS_ACCESS_KEY` used for S3 interactions (Deprecated)

`AWS_SECRET_KEY` used for S3 interactions (Deprecated)

`S3_BUCKET` e.g., _s3://database-backups_ **NOTE: no trailing slash**

>**It's recommended that your S3 bucket have versioning turned on.**  Each backup creates a file of the form _DB_NAME_.sql.gz. If versioning is not turned on, the previous backup file will be replaced with the new one, resulting in a single level of backups.

`B2_BUCKET` (optional) Name of the Backblaze B2 bucket, e.g., _database-backups_. When `B2_BUCKET` is defined, the backup file is copied to the B2 bucket in addition to the S3 bucket.

>**It's recommended that your B2 bucket have versioning and encryption turned on.** Each backup creates a file of the form _DB_NAME_.sql.gz. If versioning is not turned on, the previous backup file will be replaced with the new one, resulting in a single level of backups. Encryption may offer an additional level of protection from attackers. It also has the side effect of preventing downloads of the file via the Backblaze GUI (you'll have to use the `b2` command or the Backblaze API).

`B2_APPLICATION_KEY_ID` (optional; required if `B2_BUCKET` is defined) Backblaze application key ID

`B2_APPLICATION_KEY` (optional; required if `B2_BUCKET` is defined) Backblaze application key secret

`B2_HOST`  (optional; required if `B2_BUCKET` is defined) Backblaze B2 bucket's `Endpoint`

## Docker
This image is built automatically to GitHub Packages (GHCR)

## Playing with it locally
You'll need [Docker](https://www.docker.com/get-docker), [Docker Compose](https://docs.docker.com/compose/install/), and [Make](https://www.gnu.org/software/make/).

1. Copy `local.env.dist` to `local.env`.
2. Edit `local.env` to supply values for the variables.
3. Ensure you have a `gz` dump in your S3 bucket to be used for testing.  A test database is provided as part of this project in the `test` folder. You can copy it to S3 as follows:
* `aws s3 cp test/world.sql.gz  ${S3_BUCKET}/world.sql.gz`
4. `make db`  # creates the Postgres DB server
5. `make restore`  # restores the DB dump file
6. `docker ps -a`  # get the Container ID of the exited restore container
7. `docker logs <containerID>`  # review the restoration log messages
8. `make backup`  # create a new DB dump file
9. `docker ps -a`  # get the Container ID of the exited backup container
10. `docker logs <containerID>`  # review the backup log messages
11. `make restore`  # restore the DB dump file from the new backup
12. `docker ps -a`  # get the Container ID of the exited restore container
13. `docker logs <containerID>`  # review the restoration log messages
14. `make clean`  # remove containers and network
15. `docker volume ls`  # find the volume ID of the Postgres data container
16. `docker volume rm <volumeID>`  # remove the data volume
17. `docker images`  # list existing images
18. `docker image rm <imageID ...>`  # remove images no longer needed
