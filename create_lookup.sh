#!/bin/bash

# ----------------------------
# Configuration
# ----------------------------

# Sensitive column name patterns
#SENSITIVE_KEYS=("email" "*phone*" "*mobile*" "*ssn*" "*cssn*" "*city*" "*zip*" "*account*")
SENSITIVE_REGEX="email|phone|phone[_]?no|mobile|mobile[_]?no|ssn|cssn|city|city[_]?name|zip|zipcode|account|account[_]?number"

# Target database and table for logging
LOOKUP_DB="security_logs"
LOOKUP_TABLE="lookup"

# ----------------------------
# Create lookup table if not exists
# ----------------------------

sudo mysql --defaults-file=$HOME/.my.cnf -e "
CREATE DATABASE IF NOT EXISTS $LOOKUP_DB;
USE $LOOKUP_DB;
CREATE TABLE IF NOT EXISTS $LOOKUP_TABLE (
    id INT AUTO_INCREMENT PRIMARY KEY,
    database_name VARCHAR(100),
    table_name VARCHAR(100),
    column_name VARCHAR(100),
    primary_key TINYINT(1),
    to_mask TINYINT(1)
);
"


# Scan each database

# Get list of user databases (excluding system databases and the logging one)
databases=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e \
"SHOW DATABASES;" | grep -Ev "^(information_schema|mysql|performance_schema|sys|$LOOKUP_DB)$")

# Loop through databases
for db in $databases; do
    echo "🔍 Scanning database: $db"
    
    # Get all tables in the current database
    tables=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e \
    "SELECT table_name FROM information_schema.tables WHERE table_schema='$db';")

    # Loop through tables
    for table in $tables; do
        # Get all columns and their keys (to check for PK)
        columns=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
            SELECT column_name, column_key FROM information_schema.columns
            WHERE table_schema='$db' AND table_name='$table';"
        )

        # Loop through columns
        while IFS=$'\t' read -r col_name col_key; do
            is_pk=0
            [[ "$col_key" == "PRI" ]] && is_pk=1

           col_lower=$(echo "$col_name" | tr '[:upper:]' '[:lower:]')
            to_mask=0
            for keyword in "${SENSITIVE_REGEX[@]}"; do
                keyword_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
                if [[ "$col_lower" == *"$keyword_lower"* ]]; then
                    to_mask=1
                    break
                fi
            done

            # Insert into the lookup table
            sudo mysql --defaults-file=$HOME/.my.cnf -e "
                INSERT INTO $LOOKUP_DB.$LOOKUP_TABLE (database_name, table_name, column_name, primary_key, to_mask)
                VALUES ('$db', '$table', '$col_name', $is_pk, $to_mask);"

        done <<< "$columns"
    done
done

echo "Sensitive column scan complete. Results stored in $LOOKUP_DB.$LOOKUP_TABLE."
