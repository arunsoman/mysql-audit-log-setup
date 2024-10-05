#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: setup_audit_logs.sh
# Description: Creates audit log tables and triggers for specified MySQL tables.
# Compatibility: MySQL 8.0+
# -----------------------------------------------------------------------------

# Exit immediately if a command exits with a non-zero status
set -e

# Enable debug mode if needed
# set -x

# ---------------------------- Configuration ----------------------------------

# Variables to hold MySQL connection details
DB_HOST=""
DB_USER=""
DB_PASS=""
DB_NAME=""

PAGE_SIZE=10               # Number of tables to display per page
LOG_FILE="audit_log_setup.log"  # Log file path

# ---------------------------- Logging Setup ----------------------------------

# Redirect stdout and stderr to log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "----------------------------------------"
echo "Audit Log Setup Script Started at $(date)"
echo "----------------------------------------"

# ---------------------------- Function Definitions --------------------------

# Function to securely read user input for MySQL credentials
read_mysql_credentials() {
  echo "Please enter your MySQL connection details."

  # Prompt for MySQL Host
  read -rp "MySQL Host (e.g., localhost): " DB_HOST
  DB_HOST=${DB_HOST:-localhost}  # Default to localhost if empty

  # Prompt for MySQL Username
  read -rp "MySQL Username: " DB_USER

  # Prompt for MySQL Password (hidden input)
  read -s -rp "MySQL Password: " DB_PASS
  echo

  # Prompt for Database Name
  read -rp "Database Name (Schema): " DB_NAME

  # Validate inputs
  if [[ -z "$DB_USER" || -z "$DB_PASS" || -z "$DB_NAME" ]]; then
    echo "Error: Username, password, and database name are required."
    exit 1
  fi
}

# Function to validate table names (alphanumeric and underscores only)
validate_table_name() {
  local name="$1"
  if [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]]; then
    return 0
  else
    return 1
  fi
}

# Function to retrieve primary key column for a given table
get_primary_key() {
  local table="$1"
  mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '$DB_NAME'
      AND TABLE_NAME = '$table'
      AND COLUMN_KEY = 'PRI'
    LIMIT 1;
  "
}

# Function to create the audit log table
create_audit_log_table() {
  local table="$1"
  local audit_table="${table}_audit_log"

  echo "Creating audit log table '$audit_table'..."

  mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" <<EOF
CREATE TABLE IF NOT EXISTS \`${audit_table}\` (
  id BIGINT NOT NULL AUTO_INCREMENT,
  row_id BIGINT NOT NULL,
  old_row_data JSON,
  new_row_data JSON,
  dml_type ENUM('INSERT', 'UPDATE', 'DELETE') NOT NULL,
  dml_timestamp DATETIME NOT NULL,
  dml_created_by VARCHAR(255) NOT NULL,
  trx_timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB;
EOF

  echo "Audit log table '$audit_table' created or already exists."
}

# Function to create triggers for the selected table
create_triggers() {
  local table="$1"
  local pk_column="$2"
  local audit_table="${table}_audit_log"

  echo "Creating triggers for table '$table'..."

  # Retrieve column names and types
  columns=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
    SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME, ':', DATA_TYPE))
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = '$DB_NAME'
      AND TABLE_NAME = '$table';
  ")

  # Create JSON_OBJECT string for columns
  old_json_columns=""
  new_json_columns=""
  for column_info in $(echo $columns | tr ',' ' '); do
    column=$(echo $column_info | cut -d':' -f1)
    data_type=$(echo $column_info | cut -d':' -f2)
    
    # Handle different data types
    case $data_type in
      tinyint|smallint|mediumint|int|bigint|float|double|decimal)
        old_json_columns+="'$column', CAST(OLD.$column AS CHAR), "
        new_json_columns+="'$column', CAST(NEW.$column AS CHAR), "
        ;;
      date|datetime|timestamp)
        old_json_columns+="'$column', DATE_FORMAT(OLD.$column, '%Y-%m-%d %H:%i:%s'), "
        new_json_columns+="'$column', DATE_FORMAT(NEW.$column, '%Y-%m-%d %H:%i:%s'), "
        ;;
      *)
        old_json_columns+="'$column', OLD.$column, "
        new_json_columns+="'$column', NEW.$column, "
        ;;
    esac
  done
  old_json_columns=${old_json_columns%, }
  new_json_columns=${new_json_columns%, }

  mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" <<EOF
DELIMITER //

DROP TRIGGER IF EXISTS \`${table}_after_insert\`//
CREATE TRIGGER \`${table}_after_insert\`
AFTER INSERT ON \`${table}\`
FOR EACH ROW
BEGIN
  INSERT INTO \`${audit_table}\` (row_id, new_row_data, dml_type, dml_timestamp, dml_created_by)
  VALUES (
    NEW.\`${pk_column}\`,
    JSON_OBJECT($new_json_columns),
    'INSERT',
    NOW(),
    USER()
  );
END//

DROP TRIGGER IF EXISTS \`${table}_after_update\`//
CREATE TRIGGER \`${table}_after_update\`
AFTER UPDATE ON \`${table}\`
FOR EACH ROW
BEGIN
  INSERT INTO \`${audit_table}\` (row_id, old_row_data, new_row_data, dml_type, dml_timestamp, dml_created_by)
  VALUES (
    OLD.\`${pk_column}\`,
    JSON_OBJECT($old_json_columns),
    JSON_OBJECT($new_json_columns),
    'UPDATE',
    NOW(),
    USER()
  );
END//

DROP TRIGGER IF EXISTS \`${table}_after_delete\`//
CREATE TRIGGER \`${table}_after_delete\`
AFTER DELETE ON \`${table}\`
FOR EACH ROW
BEGIN
  INSERT INTO \`${audit_table}\` (row_id, old_row_data, dml_type, dml_timestamp, dml_created_by)
  VALUES (
    OLD.\`${pk_column}\`,
    JSON_OBJECT($old_json_columns),
    'DELETE',
    NOW(),
    USER()
  );
END//

DELIMITER ;
EOF

  echo "Triggers for table '$table' created successfully."
}


# ---------------------------- Main Script -------------------------------------

# Prompt user for MySQL credentials and database details
read_mysql_credentials

# Check if the specified database exists
if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "USE \`${DB_NAME}\`;" 2>/dev/null; then
  echo "Error: Database '$DB_NAME' does not exist or credentials are incorrect."
  exit 1
fi

# Infinite loop to allow multiple table processing
while true; do
  # Fetch all tables excluding audit log tables, without column headers
  echo "Fetching table list from database '$DB_NAME'..."
  TABLES=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "SHOW TABLES;" | grep -v '_audit_log$')
  TOTAL_TABLES=$(echo "$TABLES" | wc -l)

  if [[ "$TOTAL_TABLES" -eq 0 ]]; then
    echo "No tables found in database '$DB_NAME' excluding audit log tables."
    exit 0
  fi

  CURRENT_PAGE=1
  TOTAL_PAGES=$(( (TOTAL_TABLES + PAGE_SIZE - 1) / PAGE_SIZE ))

  while true; do
    START_INDEX=$(( (CURRENT_PAGE - 1) * PAGE_SIZE + 1 ))
    END_INDEX=$(( CURRENT_PAGE * PAGE_SIZE ))
    if [ "$END_INDEX" -gt "$TOTAL_TABLES" ]; then
      END_INDEX=$TOTAL_TABLES
    fi

    echo -e "\nAvailable tables (Page $CURRENT_PAGE of $TOTAL_PAGES):"
    echo "$TABLES" | sed -n "${START_INDEX},${END_INDEX}p"

    echo -e "\nOptions:"
    if [ "$CURRENT_PAGE" -lt "$TOTAL_PAGES" ]; then
      echo "n - Next page"
    fi
    if [ "$CURRENT_PAGE" -gt 1 ]; then
      echo "p - Previous page"
    fi
    echo "Enter the name of the table to create an audit log for (or type 'exit' to quit):"
    read -rp "> " TABLE_NAME

    # Handle user input
    case "$TABLE_NAME" in
      n|N)
        if [ "$CURRENT_PAGE" -lt "$TOTAL_PAGES" ]; then
          ((CURRENT_PAGE++))
        else
          echo "You are on the last page."
        fi
        ;;
      p|P)
        if [ "$CURRENT_PAGE" -gt 1 ]; then
          ((CURRENT_PAGE--))
        else
          echo "You are on the first page."
        fi
        ;;
      exit|EXIT|e|E)
        echo "Exiting script."
        exit 0
        ;;
      *)
        # Validate table name
        if validate_table_name "$TABLE_NAME"; then
          if echo "$TABLES" | grep -iwq "^${TABLE_NAME}$"; then
            echo "Processing table '$TABLE_NAME'..."

            # Retrieve primary key
            PK_COLUMN=$(get_primary_key "$TABLE_NAME")
            if [[ -z "$PK_COLUMN" ]]; then
              echo "Error: Table '$TABLE_NAME' does not have a primary key. Skipping."
              break
            fi

            echo "Primary key for table '$TABLE_NAME' is '$PK_COLUMN'."

            # Create audit log table
            create_audit_log_table "$TABLE_NAME"

            # Create triggers
            create_triggers "$TABLE_NAME" "$PK_COLUMN"

            echo "Audit log setup completed for table '$TABLE_NAME'."

            # Ask user if they want to process another table
            echo "Do you want to process another table? (y/n):"
            read -rp "> " ANSWER
            case "$ANSWER" in
              y|Y)
                break
                ;;
              *)
                echo "Exiting script."
                exit 0
                ;;
            esac
          else
            echo "Error: Table '$TABLE_NAME' does not exist in database '$DB_NAME'. Please try again."
          fi
        else
          echo "Invalid table name. Please use only alphanumeric characters and underscores."
        fi
        ;;
    esac
  done
done
