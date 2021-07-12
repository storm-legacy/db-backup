#!/usr/bin/env bash

# * VARIABLES
# keep last pwd
LAST_PWD=`pwd`
# script location for ease of file manipulating
SCRIPT_PWD=`cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd`
#move to script location
cd $SCRIPT_PWD

#COLORS
COLOR_CYAN='\e[36m'
COLOR_BROWN='\e[33m'
COLOR_RED="\e[31m"
COLOR_GREEN="\e[32m"
COLOR_RESET="\e[0m"

# constants
TMP="$SCRIPT_PWD/tmp"
LOG_FILE="$SCRIPT_PWD/0.log"
BAK_DIR="$SCRIPT_PWD/backups"
CONFIG_DIR="/root/.mysql-bak"
SSHFS="$SCRIPT_PWD/sshfs"
DB_TMP="$TMP/db"

MYSQLDUMP="/usr/bin/mysqldump"
declare -A MYSQL
declare -A SFTP
declare -A ARCHIVE 



# * FUNCTIONS
# convert values to look nicer
# https://gist.github.com/jpluimers/0f21bf1d937fe0b9b4044f21944a90ec
bytesToHumanSI() {
    b=${1:-0}; d=''; s=0; S=(Bytes {k,M,G,T,E,P,Z,Y}B)
    while ((b > 1000)); do
        d="$(printf ".%02d" $((b % 1000 * 100 / 1000)))"
        b=$((b / 1000))
        let s++
    done
    echo "$b$d ${S[$s]}"
}

#check for errors in dump operations
check_mysqldump_err() {
  last_line=$(cat $LOG_FILE | tail -n1)

  if [[ "$last_line" == *"error"* ]]; then
    exit 11
  fi
}

# Check if errors occured
err_check() {
  err_code=$1
  
  if [[ "$?" != "0" ]]; then
    error_code=$1
    echo -e "[ERR] Error $err_code occured. Check log for more informations!"
    exit 10
  fi
}

# function exectued on exit
exit_script() {
  umount_sshfs #umount sshfs

  # delete temp folder
  if [[ -d "$TMP" ]]; then rm -rf "$TMP"; fi

  cd $LAST_PWD # return to last_pwd
}
trap exit_script EXIT

# encryption and decryption functions
salt='YqaQYL6YGY64pPHtyem9UIs6zJYp5bxR9ywfWhF65uLJ2gH6QOrdVziN3pN99aQeY0Rbgf6a7KUWfDwi'
encrypt_passwd() {
  pass=`echo $1 | openssl enc -aes-256-cbc -md sha512 -a -pbkdf2 -iter 100000 -salt -pass pass:$salt`
  echo $pass
}

decrypt_passwd() {
  pass=`echo $1 | openssl enc -aes-256-cbc -md sha512 -a -d -pbkdf2 -iter 100000 -salt -pass pass:$salt`
  echo $pass
}

# load mysql-bak.conf
load_sources() {
  # check if file exists
  if [[ -f $CONFIG_DIR/mysql-bak.conf ]]
  then
    source $CONFIG_DIR/mysql-bak.conf
  else
    echo -e "[ERR] Config file does not exist. Try ./db-backup.sh reconfigure. Your backed up data won't be removed."
  fi

  MYSQL["ip"]=$mysql_ip
  MYSQL["port"]=$mysql_port
  MYSQL["databases"]=$mysql_databases
  MYSQL["user"]=$mysql_user
  MYSQL["passwd"]=$(decrypt_passwd $mysql_passwd)

  SFTP["ip"]=$sftp_ip
  SFTP["dir"]=$sftp_dir
  SFTP["user"]=$sftp_user
  SFTP["passwd"]=$(decrypt_passwd $sftp_passwd)

  ARCHIVE["passwd"]=$(decrypt_passwd $arch_passwd)
  ARCHIVE["backups_keep"]=$backups_keep
  ARCHIVE["keep_local"]=$keep_local
}

# Mount sshfs
mount_sshfs() {
  # create temporary dir
  if [[ ! -d "$SSHFS" ]]; then 
    mkdir -p "$SSHFS"
  fi

  #umount if exists for some reason
  umount -l "$SSHFS" > /dev/null 2>&1
  # mount passing password
  echo "${SFTP["passwd"]}" | /usr/bin/sshfs -o password_stdin ${SFTP["user"]}@${SFTP["ip"]}:/backups $SSHFS

}

# umount sshfs
umount_sshfs() {
  cd $SCRIPT_PWD
  umount "$SSHFS" > /dev/null 2>&1
  rm -r $SSHFS > /dev/null 2>&1
}

# list files on sftp server
# ! not connected to the main script
list_remote_files() {
  declare -A backup

  list=$(ls $SSHFS)
  echo -e "$COLOR_CYAN\n\n[REMOTE BACKUPS]\n"
  cd $SSHFS
  i=0
  IFS=$'\n'
  for item in $list
  do
    i=$(expr $i + 1)
    backup["time"]=$(stat --printf="%.19y" $item)
    # backup["size"]=$(bytesToHumanSI $(stat --printf="%s" $item))
    backup["size"]=$(stat --printf="%s" $item)
    backup["size"]=$(bytesToHumanSI ${backup["size"]})
    echo -e "  ($i)[${backup['size']}][${backup['time']}] $item"
  done
  echo -e "$COLOR_RESET"
}

# list localy stored files
# ! not connected to the main script
list_local_files() {
  declare -A backup

  list=$(ls $BAK_DIR)
  echo -e "$COLOR_BROWN\n\n[LOCAL BACKUPS]\n"
  cd $BAK_DIR
  i=0
  IFS=$'\n'
  for item in $list
  do
    i=$(expr $i + 1)
    backup["time"]=$(stat -c "%.19y" $item)
    backup["size"]=$(stat -c "%s" $item)
    backup["size"]=$(bytesToHumanSI ${backup["size"]})
    echo -e "  ($i) [${backup['size']}][${backup['time']}] $item"
  done
  echo -e "$COLOR_RESET"
}

#initial configuration
init_config() {
  # Check if config folder exists
  if [[ ! -d "$CONFIG_DIR" ]]
  then
    mkdir $CONFIG_DIR
    chmod -R 700 $CONFIG_DIR
  fi

  echo -e "[WARN] Configure basic functionality of the script"

  # MySQL
  read -p "> MySQL server IP [127.0.0.1]: " mysql_ip
  mysql_ip=${mysql_ip:-'127.0.0.1'}
  read -p "> Mysql server port [3306]: " mysql_port
  mysql_port=${mysql_port:-'3306'}

  while [ "$mysql_databases" == "" ]
  do
    read -p "> Databases to backup [user region ...]: " mysql_databases
  done

  read -p "> MySQL user [root]: " mysql_user
  mysql_user=${mysql_user:-root}

  while [ "$mysql_passwd" == "" ]
  do
    read -sp "> MySQL password: " mysql_passwd
    echo ""
  done

  # SFTP
  echo -e " "
  read -p "> SFTP server IP [127.0.0.1]: " sftp_ip
  sftp_ip=${sftp_ip:-'127.0.0.1'}
  read -p "> SFTP backups directory [/backups]: " sftp_dir
  sftp_dir=${sftp_dir:-'/backups'}
  read -p "> SFTP user [sftp]: " sftp_user
  sftp_user=${sftp_user:-sftp}
  while [ "$sftp_passwd" == "" ]
  do
    read -sp "> SFTP password: " sftp_passwd
    echo -e " "
  done


  echo -e " "
  read -sp "> Password to decrypt an archive: " arch_passwd
  echo -e " "
  read -sp "> Confirm password: " arch_passwd_confirm
  echo -e " "
  while [ "$arch_passwd" != "$arch_passwd_confirm" ]
  do
    read -sp "> Password to decrypt an archive: " arch_passwd
    echo -e " "
    read -sp "> Confirm password: " arch_passwd_confirm
    echo -e " "
  done

  read -p "> Number of backups to keep [7]: " backups_keep
  backups_keep=${backups_keep:-7}

  while true; do
    read -p "> Keep local copy of backup? [y/n]: " yn
    case $yn in
        [Yy]* )
          backups_local=true
          break;;
        [Nn]* )
          backups_local=false
          break;;
        * ) echo "Please answer [y]es/[n]o";;
    esac
  done


  echo -e "\n[WARN] Confirm your settings:"
  echo -e "\n [MySQL]"
  echo -e " mysql_ip = $mysql_ip"
  echo -e " mysql_port = $mysql_port"
  echo -e " mysql_databases = $mysql_databases"
  echo -e " mysql_user = $mysql_user"
  echo -e " mysql_passwd = (*******)"

  echo -e "\n [SFTP]"
  echo -e " sftp_ip = $sftp_ip"
  echo -e " sftp_dir = $sftp_dir"
  echo -e " sftp_user = $sftp_user"
  echo -e " sftp_passwd = (*******)"

  echo -e "\n [Archive]"
  echo -e " arch_passwd = (*******)"
  echo -e " backups_keep = $backups_keep"
  echo -e " keep_local = $backups_local\n"
  
  while true; do
    read -p "Are those settings correct? [y/n]: " yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please answer [y]es/[n]o.";;
    esac
  done

  #create config file
  echo "# MySQL configuration" > $CONFIG_DIR/mysql-bak.conf
  echo "mysql_ip=$mysql_ip" >> $CONFIG_DIR/mysql-bak.conf
  echo "mysql_port=$mysql_port" >> $CONFIG_DIR/mysql-bak.conf
  echo "mysql_databases=\"$mysql_databases\"" >> $CONFIG_DIR/mysql-bak.conf
  echo "mysql_user=$mysql_user" >> $CONFIG_DIR/mysql-bak.conf
  echo "mysql_passwd=$(encrypt_passwd $mysql_passwd)" >> $CONFIG_DIR/mysql-bak.conf
  echo "" >> $CONFIG_DIR/mysql-bak.conf
  echo "# SFTP configuration" >> $CONFIG_DIR/mysql-bak.conf
  echo "sftp_ip=$sftp_ip" >> $CONFIG_DIR/mysql-bak.conf
  echo "sftp_dir=$sftp_dir" >> $CONFIG_DIR/mysql-bak.conf
  echo "sftp_user=$sftp_user" >> $CONFIG_DIR/mysql-bak.conf
  echo "sftp_passwd=$(encrypt_passwd $sftp_passwd)" >> $CONFIG_DIR/mysql-bak.conf
  echo "" >> $CONFIG_DIR/mysql-bak.conf
  echo "# Archive" >> $CONFIG_DIR/mysql-bak.conf
  echo "arch_passwd=$(encrypt_passwd $arch_passwd)" >> $CONFIG_DIR/mysql-bak.conf
  echo "backups_keep=$backups_keep" >> $CONFIG_DIR/mysql-bak.conf
  echo "keep_local=$backups_local" >> $CONFIG_DIR/mysql-bak.conf

  #fix permissions
  chmod 600 $CONFIG_DIR/mysql-bak.conf

  echo -e "[INFO] Config file succesfuly created! Run script again."
}


# * PRIMARY CHECKS OF THE SCRIPT
# Check if script is run as a root
if [[ "$(id -u)" != "0" ]];
then
  echo -e "[ERR] You do not have enough privileges. Please run script as a root."
  exit 127
fi



# * COMMANDS
# Config file creation wizard
if [[ ! -f "$CONFIG_DIR/mysql-bak.conf" ]] || [[ "$1" == "reconfigure" ]]
then
  init_config
  exit 0

# help
elif [[ "$1" == "help" ]]
then
  echo -e "[HELP]"
  echo -e " remote -> list remote backups"
  echo -e " local -> list local backups"
  echo -e " reset -> reconfigure script [backed up data won't be lost]"
  exit 0;

#just list files on remote server
elif [[ "$1" == "ls-remote" ]]
then
  load_sources
  mount_sshfs
  list_remote_files
  exit 0

#just list local backups
elif [[ "$1" == "ls-local" ]]
then
  load_sources
  list_local_files
  exit 0

# If file exists read information from file
elif [[ "$1" == "" ]]
then
  load_sources

else
  echo -e "[ERR] Command does not exist. Try again."
  exit 12;
fi

# # ?  EXECUTION PART OF THE SCRIPT


# * CREATING DUMP
# prepare command for mysqldump
CMD_BASE="$MYSQLDUMP  \
  --defaults-file=$TMP/.my.cnf
  -h ${MYSQL['ip']} \
  -P ${MYSQL['port']} \
  --events --routines --quick \
  --single-transaction --verbose -B"

echo -e "[INFO] Connecting to ${MYSQL['ip']}:${MYSQL['port']}"

# create temporary dir
if [[ -d "$TMP" ]]; then 
  rm -rf "$TMP/*"
else
  mkdir "$TMP"
fi

# create temp .my.cnf file for database access
echo -e "[mysqldump]\nuser=${MYSQL['user']}\npassword=${MYSQL['passwd']}" > $TMP/.my.cnf
chmod 600 $TMP/.my.cnf

# loop through declared databases
# must assure that folder has rwx permissions for mysql and user executing script
mkdir -p "$DB_TMP"
chown -R $USER:mysql "$DB_TMP"
chmod -R 770 "$DB_TMP"
cd "$DB_TMP/$x"

for x in ${MYSQL['databases']}; do
  echo -e "[INFO] '$x' backup"
  # echo "$CMD_BASE --tab=$TMP/$x $x"
  $CMD_BASE $x --result-file="$x.sql" 2>&1 | tee -a $LOG_FILE
  check_mysqldump_err
done

# Remove .my.cnf file
rm $TMP/.my.cnf



# * CREATING AND ENCRYPTING ARCHIVE
# Create encrypted archive
echo -e "[INFO] Creating encrypted *.tar.gz.enc archive"
ARCHIVE["name"]="dbBak-`date +'%Y-%m-%d_%H-%M-%S'`.tar.gz.enc"
cd $DB_TMP
tar -cz * | openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 10000 -salt -pass pass:${ARCHIVE["passwd"]} -out ${ARCHIVE["name"]} 2>&1 | tee -a $LOG_FILE
err_check "0x0002"

# check if backup dir exists
if [[ ! -d  "$BAK_DIR" ]]; then mkdir $BAK_DIR; fi
mv ${ARCHIVE["name"]} $BAK_DIR
chmod 640 $BAK_DIR/${ARCHIVE["name"]}

# Remove tmp *.sql files
cd $BAK_DIR
rm -rf $DB_TMP



# * DATA TRANSFER TO SERVER
# in this case via SFTP
echo -e "[INFO] Transfering backup to SFTP server"

# mount sshfs
mount_sshfs
cd $SSHFS

# transfer file to remote location
/usr/bin/rsync $BAK_DIR/${ARCHIVE["name"]} $SSHFS --progress 2>&1 | tee -a $LOG_FILE
err_check "0x0003"

# if not specified, remove local backup of the file
if [[ "${ARCHIVE["keep_local"]}" != "true" ]]
then
  echo -e "[INFO] Discarding local backup file"
  rm $BAK_DIR/${ARCHIVE["name"]}
fi


# * LIST BACKUPS ON SERVER
declare -A BACKUPS
BACKUPS["list"]=$(ls .)
BACKUPS["number"]=$(echo ${BACKUPS["list"]} | wc -w)
echo -e "\n[INFO] Server already stores ${BACKUPS["number"]} backup(s)!"

# calculate backups to remove
BACKUPS["rm_number"]=$(expr ${BACKUPS["number"]} - ${ARCHIVE["backups_keep"]})

# vars
declare -A bak
i=0

# iterate through lines
IFS=$'\n'
for item in ${BACKUPS["list"]}
do
  # increment on every check
  i=$(expr $i + 1)

  bak["time"]=$(stat --printf="%.19y" $item)
  bak["size"]=$(stat --printf="%s" $item)
  bak["size"]=$(bytesToHumanSI ${bak["size"]})


  # if copy is going to be removed - mark red
  # if copies to delete run out
  if [[ "${BACKUPS['rm_number']}" -gt 0 ]]
  then
    echo -e "$COLOR_RED (-)[${bak['size']}][${bak['time']}] $item$COLOR_RESET"
    BACKUPS["rm_number"]=$(expr ${BACKUPS["rm_number"]} - 1)
    BACKUPS["to_remove"]="${BACKUPS['to_remove']}$item:" # prepare backups to be removed

  # if copy is new - mark green
  # if number of itereted copy matches number of copies on server
  elif [[ "$i" == "${BACKUPS['number']}" ]]
  then
    echo -e "$COLOR_GREEN (+)[${bak['size']}][${bak['time']}] $item$COLOR_RESET"

  # others normal
  else
    echo -e " ($i)[${bak['size']}][${bak['time']}] $item"
  fi
done



# * REMOVE OLDER BACKUPS
echo -e "\n[INFO] Discarding older remote backups"
# removing remote files
IFS=":"
for item in ${BACKUPS["to_remove"]}
do
  rm $item
  err_check "0x0005"
done

# removing local files
# ! different method than above
echo -e "[INFO] Discarding older local backups"
cd $BAK_DIR
# list only files
find . -type f -printf '%T@\t%p\n' |
sort -t $'\t' -g | 
head -n -${ARCHIVE["backups_keep"]} | 
cut -d $'\t' -f 2- |
xargs rm > /dev/null 2>&1


# * FINISHED
echo -e "$COLOR_GREEN[INFO] Operation finished successfuly! $COLOR_RESET"