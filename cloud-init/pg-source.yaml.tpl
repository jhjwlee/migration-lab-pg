#cloud-config
# cloud-init/pg-source.yaml
# Ubuntu 24.04 + PostgreSQL 16 + CarMarket 스키마 + 시드 50K + logical replication
#
# 주입 변수 (envsubst로 치환):
#   ${PG_PWD}             - postgres super user 비밀번호
#   ${MIGRATION_PWD}      - migrationuser 비밀번호 (REPLICATION 권한)

package_update: true
package_upgrade: false

packages:
  - postgresql-16
  - postgresql-contrib-16
  - python3-psycopg2

write_files:
  # ============================================================
  # 1. PostgreSQL 설정: 외부 접근 + logical replication
  # ============================================================
  - path: /etc/postgresql/16/main/conf.d/migration.conf
    permissions: '0644'
    owner: postgres:postgres
    content: |
      # Migration lab — overrides postgresql.conf
      listen_addresses = '*'
      wal_level = logical
      max_wal_senders = 10
      max_replication_slots = 10
      max_worker_processes = 16

  # pg_hba.conf — 외부 접근 + replication 허용
  - path: /tmp/pg_hba_migration.conf
    permissions: '0644'
    content: |
      # Migration lab additional rules
      host    all            all              0.0.0.0/0    md5
      host    replication    migrationuser    0.0.0.0/0    md5
      host    all            migrationuser    0.0.0.0/0    md5

  # ============================================================
  # 2. 스키마 + 시드 SQL
  # ============================================================
  - path: /tmp/schema.sql
    permissions: '0644'
    content: |
      \c carmarket

      DROP TABLE IF EXISTS inquiries CASCADE;
      DROP TABLE IF EXISTS cars      CASCADE;
      DROP TABLE IF EXISTS users     CASCADE;

      CREATE TABLE users (
          user_id    SERIAL PRIMARY KEY,
          name       VARCHAR(100) NOT NULL,
          email      VARCHAR(200) NOT NULL UNIQUE,
          phone      VARCHAR(20),
          user_type  VARCHAR(10) NOT NULL DEFAULT 'both'
                     CHECK (user_type IN ('seller','buyer','both')),
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE cars (
          car_id      SERIAL PRIMARY KEY,
          seller_id   INT NOT NULL REFERENCES users(user_id),
          brand       VARCHAR(50)  NOT NULL,
          model       VARCHAR(100) NOT NULL,
          year        INT          NOT NULL,
          price       NUMERIC(12,0) NOT NULL,
          mileage     INT          NOT NULL,
          fuel_type   VARCHAR(20),
          description TEXT,
          status      VARCHAR(20) NOT NULL DEFAULT 'available'
                      CHECK (status IN ('available','reserved','sold')),
          created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE inquiries (
          inquiry_id SERIAL PRIMARY KEY,
          car_id     INT NOT NULL REFERENCES cars(car_id),
          buyer_id   INT NOT NULL REFERENCES users(user_id),
          message    TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX idx_cars_brand   ON cars(brand);
      CREATE INDEX idx_cars_status  ON cars(status);
      CREATE INDEX idx_cars_created ON cars(created_at DESC);

  # 시드 Python (50K)
  - path: /tmp/seed.py
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """Seed CarMarket: 5K users + 50K cars + 30K inquiries."""
      import psycopg2, random, sys

      conn = psycopg2.connect(
          host='localhost', database='carmarket',
          user='postgres', password=sys.argv[1]
      )
      conn.autocommit = False
      cur = conn.cursor()

      brands = ['Hyundai','Kia','Genesis','BMW','MercedesBenz','Audi',
                'Chevrolet','Ssangyong','Renault','Tesla']
      models = {
        'Hyundai':['Sonata','Avante','Grandeur','SantaFe','Kona','Casper'],
        'Kia':['K5','K3','K7','Sorento','Seltos','Niro'],
        'Genesis':['G70','G80','G90','GV70','GV80'],
        'BMW':['320i','520d','X3','X5','M3'],
        'MercedesBenz':['C200','E300','S350','GLC','GLE'],
        'Audi':['A4','A6','Q5','Q7'],
        'Chevrolet':['Spark','Malibu','Trax'],
        'Ssangyong':['Tivoli','Korando','Rexton'],
        'Renault':['SM6','QM6','XM3'],
        'Tesla':['Model3','ModelY','ModelS']
      }
      fuels = ['Gasoline','Diesel','LPG','Hybrid','Electric']

      print('Seeding 5,000 users...', flush=True)
      for i in range(5000):
          cur.execute(
              "INSERT INTO users(name,email,phone,user_type) VALUES(%s,%s,%s,%s)",
              (f'user{i+1}', f'user{i+1}@test.com',
               f'010-{random.randint(1000,9999)}-{random.randint(1000,9999)}',
               random.choice(['seller','buyer','both']))
          )
          if (i+1) % 1000 == 0:
              conn.commit()
              print(f'  {i+1:>5} users', flush=True)
      conn.commit()

      print('Seeding 50,000 cars...', flush=True)
      for i in range(50000):
          brand = random.choice(brands)
          cur.execute(
              """INSERT INTO cars(seller_id,brand,model,year,price,mileage,
                                  fuel_type,description,status)
                 VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
              (random.randint(1,5000), brand, random.choice(models[brand]),
               random.randint(2015,2024),
               random.randint(5_000_000, 80_000_000),
               random.randint(1000, 200000),
               random.choice(fuels), ff'Car listing {i+1} description',
               random.choices(['available','reserved','sold'],
                              weights=[70,10,20])[0])
          )
          if (i+1) % 5000 == 0:
              conn.commit()
              print(f'  {i+1:>6} cars', flush=True)
      conn.commit()

      print('Seeding 30,000 inquiries...', flush=True)
      for i in range(30000):
          cur.execute(
              "INSERT INTO inquiries(car_id,buyer_id,message) VALUES(%s,%s,%s)",
              (random.randint(1,50000), random.randint(1,5000),
               f'Inquiry message {i+1}')
          )
          if (i+1) % 5000 == 0:
              conn.commit()
              print(f'  {i+1:>6} inquiries', flush=True)
      conn.commit()
      cur.close(); conn.close()
      print('Seeding complete: 5K+50K+30K = 85K rows', flush=True)

  # ============================================================
  # 3. Bootstrap script (실제 실행 흐름)
  # ============================================================
  - path: /opt/bootstrap/run.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      LOG=/var/log/pg-bootstrap.log
      exec > >(tee -a "$LOG") 2>&1
      echo "==========================================="
      echo "PG VM Bootstrap — $(date)"
      echo "==========================================="

      # 1. PostgreSQL 시작 + super user 비밀번호
      systemctl restart postgresql
      sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${PG_PWD}';"

      # 2. CarMarket DB 생성 + 스키마
      sudo -u postgres createdb carmarket || echo "DB exists, skipping"
      sudo -u postgres psql -f /tmp/schema.sql

      # 3. migrationuser (REPLICATION 권한)
      sudo -u postgres psql <<EOSQL
      DROP USER IF EXISTS migrationuser;
      CREATE USER migrationuser WITH PASSWORD '${MIGRATION_PWD}' REPLICATION;
      GRANT ALL PRIVILEGES ON DATABASE carmarket TO migrationuser;
      \c carmarket
      GRANT ALL ON ALL TABLES IN SCHEMA public TO migrationuser;
      GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO migrationuser;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO migrationuser;
      EOSQL

      # 4. pg_hba.conf 추가 (idempotent)
      if ! grep -q "Migration lab" /etc/postgresql/16/main/pg_hba.conf; then
        echo "" >> /etc/postgresql/16/main/pg_hba.conf
        echo "# === Migration lab (auto-added by cloud-init) ===" \
          >> /etc/postgresql/16/main/pg_hba.conf
        cat /tmp/pg_hba_migration.conf \
          >> /etc/postgresql/16/main/pg_hba.conf
      fi

      # 5. 재시작 (logical replication 적용)
      systemctl restart postgresql
      sleep 3

      # 6. 시드 (~3분 소요)
      python3 /tmp/seed.py "${PG_PWD}"

      # 7. 검증
      sudo -u postgres psql -d carmarket -c "
      SELECT 'users' AS t, COUNT(*) FROM users
      UNION ALL SELECT 'cars', COUNT(*) FROM cars
      UNION ALL SELECT 'inquiries', COUNT(*) FROM inquiries
      ORDER BY t;"

      echo "wal_level: $(sudo -u postgres psql -tAc 'SHOW wal_level')"

      # 8. 완료 마커
      touch /var/log/pg-bootstrap.done
      echo "==========================================="
      echo "Bootstrap complete — $(date)"
      echo "==========================================="

runcmd:
  - [ bash, -c, "/opt/bootstrap/run.sh || echo BOOTSTRAP_FAILED >> /var/log/pg-bootstrap.log" ]

final_message: |
  PostgreSQL VM bootstrap finished.
  Log: /var/log/pg-bootstrap.log
  Marker: /var/log/pg-bootstrap.done
