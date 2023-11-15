#!/bin/bash
set -e

# allow arguments to be passed to named
if [[ "${1:0:1}" == '-' ]]; then
    EXTRA_ARGS="${*}"
    set --
elif [[ "${1}" == "named" || "${1}" == "$(command -v named)" ]]; then
    EXTRA_ARGS="${*:2}"
    set --
fi

# The user which will start the named process.  If not specified,
# defaults to 'bind'.
BIND9_USER="${BIND9_USER:-bind}"

BIND_PATH="${BIND_PATH:-"/etc/bind"}"
KEY_FILE_NAME="${KEY_FILE_NAME:-localzone.conf.key}"
ZONE_FILE_NAME="${ZONE_FILE_NAME:-localzone.conf}"
TSIG_ALGORITHM="${TSIG_ALGORITHM:-hmac-sha256}"

parse_array() {
    local input_string="$1"
    local delimiter="$2"
    IFS="$delimiter" read -ra array <<< "$input_string"
    echo "${array[@]}"
}


# Create TSIG key file
if [ ! -e "$BIND_PATH/$KEY_FILE_NAME" ] && [ -z "${TSIG_KEY}" ] && [ "${CREATE_TSIG_KEY}" = true ]; then

    tsig-keygen -a $TSIG_ALGORITHM > $BIND_PATH/$KEY_FILE_NAME

elif [ -n "${TSIG_KEY}" ] && [ "${CREATE_TSIG_KEY}" != true ]; then

    cat > "$BIND_PATH/$KEY_FILE_NAME" <<EOF
key "tsig-key" {
        algorithm $TSIG_ALGORITHM;
        secret "$TSIG_KEY";
};

EOF
fi

# create localconfig
if [ -n "${ZONES_LIST}" ] && [ -n "${DNS_IP}" ]; then

  ZONES_LIST=($(parse_array "$ZONES_LIST" ','))
  ZONE_TTL="${ZONE_TTL:-3600}"
  ZONE_SERIAL=$(date +%s)
  ACL_CIDRS=($(parse_array "$ACL_CIDRS" ','))
  DEFAULT_FORWARDERS=("1.1.1.2" "1.0.0.2" "8.8.8.8")
  CUSTOM_FORWARDERS=($(parse_array "$FORWARDERS" ','))
  FORWARDERS=("${CUSTOM_FORWARDERS[@]:-${DEFAULT_FORWARDERS[@]}}")

# create local zone
  # if [ ! -e "$BIND_PATH/$ZONE_FILE_NAME" ]
  for ZONE_NAME in "${ZONES_LIST[@]}"
  do
    if [ -e "$BIND_PATH/$ZONE_NAME.$ZONE_FILE_NAME" ] && [ "${RFC_2136}" = true ]; then
      :
    else
      cat > $BIND_PATH/$ZONE_NAME.$ZONE_FILE_NAME <<EOF
\$TTL $ZONE_TTL

\$ORIGIN $ZONE_NAME.

@             IN     SOA    ns.$ZONE_NAME. admin.$ZONE_NAME (
                            $ZONE_SERIAL     ; serial
                            12h            ; refresh
                            15m            ; retry
                            3w             ; expire
                            2h )           ; minimum TTL

              IN     NS     ns.$ZONE_NAME.

ns            IN     A      $DNS_IP

; dns record below
;; A records
$(
  if compgen -v A_ > /dev/null; then
      # Loop through variables starting with "A_"
      for var_name in $(compgen -v A_); do
          # Remove the "A_" prefix
          short_name=${var_name#A_}
          # Echo variable name without prefix and its value
          echo "${short_name}    IN     A      ${!var_name}"
      done
  fi
)

;; CNAME records
$(
  if compgen -v CNAME_ > /dev/null; then
      for var_name in $(compgen -v CNAME_); do
          short_name=${var_name#CNAME_}
          echo "${short_name}    IN     CNAME      ${!var_name}"
      done
  fi
)

EOF
    fi
  done

# create options config
  cat > $BIND_PATH/named.conf.options <<EOF
options {
  forwarders {
$(printf '    %s;\n' "${FORWARDERS[@]}")
  };

  $(if [ -n "${ACL_CIDRS}" ]; then
    echo "allow-query { allowed; };"
  fi)

  dnssec-validation auto;

  $(if [ -n "${SLAVE_IP}" ]; then
    echo "notify yes;
  also-notify { $SLAVE_IP; };
  allow-transfer { $SLAVE_IP; };"
  fi)
};

EOF

# create local named config
  cat > $BIND_PATH/named.conf <<EOF
include "/etc/bind/named.conf.options";

$(if [ -e "$BIND_PATH/$KEY_FILE_NAME" ]; then
  echo "include $BIND_PATH/$KEY_FILE_NAME;"
fi)

$(if [ -n "${ACL_CIDRS}" ]; then
  echo "acl allowed {
$(printf '  %s;\n' "${ACL_CIDRS[@]}")
};"
fi)

$(
  for ZONE_NAME in "${ZONES_LIST[@]}"
  do
    echo "zone "$ZONE_NAME" IN {
  type master;
  file "$BIND_PATH/$ZONE_NAME.$ZONE_FILE_NAME";
  $(
    if [ -e "$BIND_PATH/$KEY_FILE_NAME" ]; then
      echo "update-policy { grant tsig-key zonesub any; };"
    fi
  )
};
"
  done
)

EOF
fi


# default behaviour is to launch named
if [[ -z "${1}" ]]; then
    echo "Starting named..."
    echo "exec $(which named) -u \"${BIND9_USER}\" -g \"${EXTRA_ARGS}\""
    exec $(command -v named) -u "${BIND9_USER}" -g ${EXTRA_ARGS}
else
    exec "${@}"
fi
