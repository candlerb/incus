test_pki() {
  if [ ! -d "/usr/share/easy-rsa/" ]; then
    echo "==> SKIP: The pki test requires easy-rsa to be installed"
    return
  fi

  # Setup the PKI.
  cp -R /usr/share/easy-rsa "${TEST_DIR}/pki"
  (
    set -e
    cd "${TEST_DIR}/pki"
    export EASYRSA_KEY_SIZE=4096

    # shellcheck disable=SC1091
    if [ -e pkitool ]; then
        . ./vars
        ./clean-all
        ./pkitool --initca
        ./pkitool lxd-client
        ./pkitool lxd-client-revoked
        # This will revoke the certificate but fail in the end as it tries to then verify the revoked certificate.
        ./revoke-full lxd-client-revoked || true
    else
        ./easyrsa init-pki
        echo "lxd" | ./easyrsa build-ca nopass
        ./easyrsa gen-crl
        ./easyrsa build-client-full lxd-client nopass
        ./easyrsa build-client-full lxd-client-revoked nopass
        mkdir keys
        cp pki/private/* keys/
        cp pki/issued/* keys/
        cp pki/ca.crt keys/
        echo "yes" | ./easyrsa revoke lxd-client-revoked
        ./easyrsa gen-crl
        cp pki/crl.pem keys/
    fi
  )

  # Setup the daemon.
  INCUS5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${INCUS5_DIR}"
  cp "${TEST_DIR}/pki/keys/ca.crt" "${INCUS5_DIR}/server.ca"
  cp "${TEST_DIR}/pki/keys/crl.pem" "${INCUS5_DIR}/ca.crl"
  spawn_incus "${INCUS5_DIR}" true
  INCUS5_ADDR=$(cat "${INCUS5_DIR}/lxd.addr")

  # Setup the client.
  INC5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  cp "${TEST_DIR}/pki/keys/lxd-client.crt" "${INC5_DIR}/client.crt"
  cp "${TEST_DIR}/pki/keys/lxd-client.key" "${INC5_DIR}/client.key"
  cp "${TEST_DIR}/pki/keys/ca.crt" "${INC5_DIR}/client.ca"

  # Confirm that a valid client certificate works.
  (
    set -e
    export INCUS_CONF="${INC5_DIR}"

    # Try adding remote using an incorrect password.
    # This should fail, as if the certificate is unknown and password is wrong then no access should be allowed.
    ! inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate --password=bar || false

    # Add remote using the correct password.
    # This should work because the client certificate is signed by the CA.
    inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate --password=foo
    inc_remote config trust ls pki-lxd: | grep lxd-client
    inc_remote remote remove pki-lxd

    # Add remote using a CA-signed client certificate, and not providing a password.
    # This should succeed and tests that the CA trust is working, as adding the client certificate to the trust
    # store without a trust password would normally fail.
    INCUS_DIR=${INCUS5_DIR} lxc config set core.trust_ca_certificates true
    inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate
    inc_remote config trust ls pki-lxd: | grep lxd-client
    inc_remote remote remove pki-lxd

    # Add remote using a CA-signed client certificate, and providing an incorrect password.
    # This should succeed as is the same as the test above but with an incorrect password rather than no password.
    inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate --password=bar
    inc_remote config trust ls pki-lxd: | grep lxd-client

    # Try removing the fingerprint.
    # This should succeed as the admin can delete all certificates.
    fingerprint="$(inc_remote config trust ls pki-lxd: --format csv | cut -d, -f4)"
    inc_remote config trust rm pki-lxd:"${fingerprint}"

    inc_remote remote remove pki-lxd

    # Replace the client certificate with a revoked certificate in the CRL.
    cp "${TEST_DIR}/pki/keys/lxd-client-revoked.crt" "${INC5_DIR}/client.crt"
    cp "${TEST_DIR}/pki/keys/lxd-client-revoked.key" "${INC5_DIR}/client.key"

    # Try adding a remote using a revoked client certificate, and the correct password.
    # This should fail, as although revoked certificates can be added to the trust store, they will not be usable.
    ! inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate --password=foo || false

    # Try adding a remote using a revoked client certificate, and an incorrect password.
    # This should fail, as if the certificate is revoked and password is wrong then no access should be allowed.
    ! inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate --password=incorrect || false
  )

  # Confirm that a normal, non-PKI certificate doesn't.
  # As INCUS_CONF is not set to INC5_DIR where the CA signed client certs are, this will cause the lxc command to
  # generate a new certificate that isn't trusted by the CA certificate and thus will not be allowed, even with a
  # correct trust password. This is because the LXD TLS listener in CA mode will not consider a client cert that
  # is not signed by the CA as valid.
  ! inc_remote remote add pki-lxd "${INCUS5_ADDR}" --accept-certificate --password=foo || false

  kill_incus "${INCUS5_DIR}"
}
