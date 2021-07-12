# DB-BACKUP
Jest to prosty skrypt pozwalający na szybkie i wygodne utworzenie kopii zapasowej wybranych baz danych InnoDB dla serwera bazodanowego MySQL.

### Założenia:
 - [X] Utworzenie kopii zapasowej bazy, bez potrzeby wstrzymywania jej pracy
 - [X] Utworzenie pliku *.sql pozwalającego na szybkie przywrócenie poszczególnych baz
 - [X] Szyfrowanie kopii zapasowej przed wysłaniem na serwer
 - [X] Możliwość przechowywania lokalnej kopii bazy jak również jej wysłania na serwer SFTP
 - [X] Kontrolowanie ilości wykonanych kopii poprzez usuwanie najstarszych


# KONFIGURACJA
## Uprawnienia użytkownika kopii zapasowej MySQL
Aby wykonać kopię zapasową, użytkownik kopii zapasowej przypisany do bazy musi posiadać uprawnienia jej odczytu, wglądu do widoków, zapisu do pliku oraz edycji wydarzeń:
```
mysql> REVOKE ALL ON *.* FROM 'bak-user'@'127.0.0.1';
mysql> GRANT SELECT, SHOW VIEW, FILE, EVENT on db1.* TO 'bak-user'@'127.0.0.1';
```

## Folder skryptu
Aby poprawnie wykonać kopię zapasową bazy, należy umieścić skrypt - w osobnym folderze, w którym będzie znajdować się jego struktura plików oraz lokalnie zapisywanie kopie zapasowe
```
bash> sudo tree .
.
├── 0.log             # -> log skryptu
├── backups           # -> folder przechowujący lokalne kopie zapasowe
│   └── *.tar.gz.enc  # -> lokalny plik kopii zapasowej
├── db-backup.sh      # -> plik egzekucyjny skryptu
├── sshfs             # -> tymczasowy punkt montowania lokalizacji SFTP
│   └── *.tar.gz.enc  # -> zdalny plik kopii zapasowej
└── tmp               # -> Tymczasowy folder skryptu
    └── db
        ├── db1.sql   # -> Plik *.sql kopiowanej bazy danych
        └── db2.sql
```
Aby możliwe było wykonanie kopii za pomocą wykorzystywanego w procesie narzędzia **mysqldump**, folder, w którym znajduje się skrypt musi posiadać uprawnienia zapisu dla grupy **mysql**.
```
chown root:mysql /path/to/script/dir
chmod 770 /path/to/script/dir         #albo 755 dla mniej bezpiecznego wariantu
```

## Pierwsze uruchomienie:

Skrypt musi zostać **uruchomiony jako root** i posiadać **uprawnienia 700**. 
#### **Jest to bardzo istotne, ponieważ użytkownik posiadający dostęp do skryptu będzie w stanie zdeszyfrować hasła znajdujące się w pliku konfiguracyjnym.**
```
bash> sudo chmod 700 ./db-backup.sh
```

### Komenda inicjująca:
```
bash> sudo ./db-backup.sh
```

Podczas pierwszego uruchomienia użytkownik zostanie poproszony o podanie informacji pozwalających na podłączenie do bazy danych i serwera sftp:
```
[WARN] Configure basic functionality of the script
> MySQL server IP [127.0.0.1]: 127.0.0.1
> Mysql server port [3306]: 3306
> Databases to backup [user region ...]: users permissions
> MySQL user [root]: backup
> MySQL password:

> SFTP server IP [127.0.0.1]: 192.168.1.254
> SFTP backups directory [/backups]: /db
> SFTP user [sftp]: backup-sftp
> SFTP password:

> Password to decrypt an archive:
> Confirm password:
> Number of backups to keep [7]: 5
> Keep local copy of backup? [y/n]: y
```
Następnie komunikat poprosi o potwierdzenie:
```
[WARN] Confirm your settings:

 [MySQL]
 mysql_ip = 127.0.0.1
 mysql_port = 3306
 mysql_databases = users permissions
 mysql_user = backup
 mysql_passwd = (*******)

 [SFTP]
 sftp_ip = 192.168.1.254
 sftp_dir = /db
 sftp_user = backup-sftp
 sftp_passwd = (*******)

 [Archive]
 arch_passwd = (*******)
 backups_keep = 5
 keep_local = true

Are those settings correct? [y/n]: y
[INFO] Config file succesfuly created! Run script again.
```
W wypadku wprowadzenia niepoprawnych danych lub chęci ich późniejszej korekty - użytkownik może użyć komendy pozwalającej na ponownienie procesu tworzenia pliku konfiguracyjnego:
```
bash> sudo ./db-backup.sh reconfigure
```

## Plik konfiguracyjny
Istnieje również możliwość wprowadzania pojedyńczych zmian bezpośrednio do pliku konfiguracyjnego bez potrzeby generowania konfiguracji od zera.
```
bash> sudo cat /root/.mysql-bak/mysql-bak.conf

# MySQL configuration
mysql_ip=127.0.0.1
mysql_port=3306
mysql_databases="users permissions"
mysql_user=backup
mysql_passwd=U2FsdGVkX1+nFH3FhH2EgAVWkKLvQhxBKTbTlSm/kd8=

# SFTP configuration
sftp_ip=192.168.1.254
sftp_dir=/db
sftp_user=backup-sftp
sftp_passwd=U2FsdGVkX1+GC0EYYgdPwt0T627rXZRPH3e9okLCf1U=

# Archive
arch_passwd=U2FsdGVkX1+7tPS83z04u1llB/S3mabyps1dWnCscdw=
backups_keep=5
keep_local=true
```

# DZIAŁANIE
## Start
Aby uruchomić skrypt, wystarczy go wywołać.
```
bash> sudo ./db-backup.sh
```
**Skrypt należy uruchomić co najmniej raz w celu potwierdzenia jego działania przed skonfigurowaniem go jako zaplanowane zadanie (cron itd.)**

## Przebieg:
Na początku następuje podłączenie do bazy, które może sprawić problemy jeśli ustawienia dla serwera mysql w pliku konfiguracyjnym (*.mysql-bak.conf*) są błędne, albo grupa **mysql** nie posiada uprawnień do zapisu w folderze ze skryptem. Poprawna prodecura zrzutu bazy powinna wyglądać tak:
```
[INFO] 'db1' backup
-- Connecting to 127.0.0.1...
-- Starting transaction...
-- Setting savepoint...
-- Retrieving table structure for table address...
-- Sending SELECT query...
-- Retrieving rows...
-- Rolling back to savepoint sp...
-- Retrieving table structure for table info...
-- Sending SELECT query...
-- Retrieving rows...
-- Rolling back to savepoint sp...
-- Retrieving table structure for table users...
-- Sending SELECT query...
-- Retrieving rows...
-- Rolling back to savepoint sp...
-- Releasing savepoint...
-- Disconnecting from 127.0.0.1...
```
Następnie generowane jest zaszyfrowane hasłem podanym przy automatycznej konfiguracji archiwum **\*.tar.gz.enc**:
```
[INFO] Creating encrypted *.tar.gz.enc archive
```

Plik kopii od teraz znajduje się w folderze **./backups** i zależnie od opcji pozostawiania archiwum lokalnego w pliku konfiguracyjnym. Zostanie usunięty po wysłaniu na serwer, albo pozostawiony, nie przekraczając limitu archiwów
```
bash> ls backups/
total 814940
-rw-r----- 1 root root 834491936 Jul 12 11:16 dbBak-2021-07-12_11-15-57.tar.gz.enc
```

Następnie zaszyfrowany plik kopii przesyłany jest za pomocą **rsync** do zdalnej lokalizacji **SFTP**
```
[INFO] Transfering backup to SFTP server
dbBak-2021-07-12_10-55-59.tar.gz.enc
    287,932,416  34%   12.71MB/s    0:00:42
```

Po zakończeniu operacji powinien wyświetlić się komunikat przedstawiający wykaz kopii (zdalnych) z zaznaczeniem nowo dodanej i usuniętych starszych kopii.
```
[INFO] Server already stores 6 backup(s)!
 (-)[834.49 MB][2021-07-12 10:03:16] dbBak-2021-07-12_10-01-06.tar.gz.enc
 (2)[834.49 MB][2021-07-12 10:13:01] dbBak-2021-07-12_10-10-51.tar.gz.enc
 (3)[834.49 MB][2021-07-12 10:17:19] dbBak-2021-07-12_10-15-06.tar.gz.enc
 (4)[834.49 MB][2021-07-12 10:48:00] dbBak-2021-07-12_10-45-49.tar.gz.enc
 (5)[834.49 MB][2021-07-12 10:53:32] dbBak-2021-07-12_10-51-13.tar.gz.enc
 (+)[834.49 MB][2021-07-12 10:58:14] dbBak-2021-07-12_10-55-59.tar.gz.enc

[INFO] Discarding older remote backups
[INFO] Discarding older local backups
```


# PRZYWRACANIE KOPII ZAPASOWEJ
## Deszyfrowanie
Żeby zdeszyfrować archiwum należy użyć tej komendy oraz wprowadzić hasło podane przy konfiguracji skryptu:
```
bash> openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 10000 -salt -d -in dbBak-XXXX-XX-XX_XX-XX-XX.tar.gz.enc -out /lokalizacja/twoja_nazwa.tar.gz

enter aes-256-cbc decryption password:
```
Gdzie:
- dbBak-XXXX-XX-XX_XX-XX-XX **.tar.gz.enc** -> **zaszyfrowane** archiwum
- /lokalizacja/twoja_nazwa **.tar.gz** -> **odszyfrowane** archiwum docelowe

#### W wypadku problemów z uprawnieniami:
```
bash> sudo chown root:$USER dbBak-XXXX-XX-XX_XX-XX-XX.tar.gz.enc
bash> sudo chmod 640 dbBak-XXXX-XX-XX_XX-XX-XX.tar.gz.enc
```


## Rozpakowywanie archiwum
Potem zawartość archiwum można wyeksportować do dowolnej innej lokalizacji **(musi istnieć)**
```
bash> tar -xzvf /lokalizacja/twoja_nazwa.tar.gz -C /dowolna/inna/lokalizacja
```

Aby ostatecznie przywrócić kopię z pliku ***.sql**, np. za pomocą komendy **mysql**:
```
bash> mysql -u uzytkownikZUprawnieniami -p < /dowolna/inna/lokalizacja/db1.sql
```
