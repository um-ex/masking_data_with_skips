#!/bin/bash

# Masking generators
generate_random_name() {
    NAMES=(Umesh Dinesh Ankit Sunny Shisir Jeevan Yubraj Milan Manisha Surya Naresh Santosh Samad Samar Sanim Aashma Purnima Gautam Suresh Abhaya Sachin Anil Kamal Narayan Krishna)
    echo "${NAMES[$RANDOM % ${#NAMES[@]}]}"
}
generate_random_email() {
    echo "$(tr -dc a-z0-9 </dev/urandom | head -c6)@cloudtech.com"
}
generate_random_phone() {
    printf "98%08d" $((RANDOM % 100000000))
}
generate_random_ssn() {
    area=$((001 + RANDOM % 734))
    [ $area -ge 666 ] && area=$((area + 1))
    group=$((01 + RANDOM % 99))
    serial=$((0001 + RANDOM % 9999))
    printf "%03d-%02d-%04d" "$area" "$group" "$serial"
}
generate_random_ip() {
    echo "$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256))"
}
generate_random_address() {
    echo "$((RANDOM%1000)) Main St, Texas, USA"
}
generate_random_account() {
    echo "$((1000000000 + RANDOM % 999999999))"
}
generate_random_dob() {
    echo "$((RANDOM % 50 + 1970))-$(printf "%02d" $((RANDOM % 12 + 1)))-$(printf "%02d" $((RANDOM % 28 + 1)))"
}
generate_random_passport() {
    echo "P$(tr -dc A-Z0-9 </dev/urandom | head -c8)"
}
generate_random_driver_license() {
    echo "DL-$(tr -dc A-Z0-9 </dev/urandom | head -c6)"
}
generate_random_credit_card() {
    base="4$(printf "%012d" $((RANDOM % 1000000000000)))"
    digits=($(echo "$base" | grep -o .))
    sum=0
    for ((i=${#digits[@]}-1, j=0; i>=0; i--, j++)); do
        d=${digits[i]}
        if [ $((j % 2)) -eq 0 ]; then
            d=$((d * 2))
            [ $d -gt 9 ] && d=$((d - 9))
        fi
        sum=$((sum + d))
    done
    check_digit=$(( (10 - (sum % 10)) % 10 ))
    echo "${base}${check_digit}"
}
generate_random_exp_date() {
    echo "$(printf "%02d" $((RANDOM % 12 + 1)))/$((RANDOM % 10 + 25))"
}
generate_random_generic() {
    echo "MASKED_$(tr -dc A-Z0-9 </dev/urandom | head -c6)"
}

# Generator selector
get_masking_function() {
    col_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    if [[ $col_lower == *email* ]]; then echo "generate_random_email"
    elif [[ $col_lower == *phone* || $col_lower == *mobile* ]]; then echo "generate_random_phone"
    elif [[ $col_lower == *ssn* || $col_lower == *cssn* ]]; then echo "generate_random_ssn"
    elif [[ $col_lower == *name* ]]; then echo "generate_random_name"
    elif [[ $col_lower == *city* || $col_lower == *zip* ]]; then echo "generate_random_address"
    elif [[ $col_lower == *account* ]]; then echo "generate_random_account"
    elif [[ $col_lower == *dob* || $col_lower == *birth* ]]; then echo "generate_random_dob"
    elif [[ $col_lower == *passport* ]]; then echo "generate_random_passport"
    elif [[ $col_lower == *driver* ]]; then echo "generate_random_driver_license"
    elif [[ $col_lower == *credit* ]]; then echo "generate_random_credit_card"
    elif [[ $col_lower == *exp* ]]; then echo "generate_random_exp_date"
    else echo "generate_random_generic"
    fi
}

# Begin masking loop
LOOKUP_DB="security_logs"
LOOKUP_TABLE="lookup"
EXCLUSION_TABLE="exclusion_list"

# Get list of columns to mask
rows=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
SELECT database_name, table_name, column_name
FROM $LOOKUP_DB.$LOOKUP_TABLE
WHERE to_mask = 1 AND primary_key = 0;
")

while IFS=$'\t' read -r db table col; do
    echo "Masking $db.$table.$col"

    func_name=$(get_masking_function "$col")

    pk_col=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = '$db' AND table_name = '$table' AND column_key = 'PRI'
        LIMIT 1;
    ")

    if [[ -n "$pk_col" ]]; then
        ids=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
            SELECT \`$pk_col\` FROM \`$db\`.\`$table\`;
        ")

     
        # Check if the exclusion_list table has this column
        column_exists=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema = '$LOOKUP_DB' AND table_name = '$EXCLUSION_TABLE' AND column_name = '$col';
        ")

        if [[ "$column_exists" -eq 1 ]]; then
            exclusions=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
                SELECT \`$col\` FROM $LOOKUP_DB.$EXCLUSION_TABLE
                WHERE \`$col\` IS NOT NULL;
            ")
        else
            exclusions=""
        fi

        for id in $ids; do
            current_val=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
                SELECT \`$col\` FROM \`$db\`.\`$table\` WHERE \`$pk_col\` = '$id' LIMIT 1;
            ")

            skip=0
            while IFS= read -r exclude_val; do
                if [[ "$current_val" == "$exclude_val" ]]; then
                    skip=1
                    break
                fi
            done <<< "$exclusions"

            if [[ "$skip" -eq 1 ]]; then
                echo "Skipping $db.$table.$col for ID $id (value in exclusion list)"
                continue
            fi

            new_val=$($func_name)
            max_len=$(sudo mysql --defaults-file=$HOME/.my.cnf -N -e "
                SELECT CHARACTER_MAXIMUM_LENGTH
                FROM information_schema.columns
                WHERE table_schema = '$db' AND table_name = '$table' AND column_name = '$col';
            ")
            if [[ "$max_len" =~ ^[0-9]+$ ]]; then
                new_val=$(echo "$new_val" | cut -c1-"$max_len")
            fi

            sudo mysql --defaults-file=$HOME/.my.cnf -e "
                UPDATE \`$db\`.\`$table\`
                SET \`$col\` = '$new_val'
                WHERE \`$pk_col\` = '$id';
            "
        done
    else
        # Fallback: whole-column mask (no primary key to filter by exclusion)
        echo "No primary key for $db.$table. Cannot apply exclusion check safely. Skipping..."
        continue
    fi
done <<< "$rows"

echo "All sensitive fields (excluding exclusions) have been masked."
