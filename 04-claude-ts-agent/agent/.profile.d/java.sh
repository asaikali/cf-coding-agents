export JAVA_HOME=/home/vcap/deps/0/apt/usr/lib/jvm/temurin-25-jdk-amd64
export PATH=$JAVA_HOME/bin:$PATH

# cflinuxfs4 ships system CA certs as a PEM bundle at
# /etc/ssl/certs/ca-certificates.crt but does not include a Java keystore.
# On a normal Ubuntu box the `ca-certificates-java` package would create
# /etc/ssl/certs/java/cacerts via a post-install hook that converts
# PEM → JKS; on cflinuxfs4 that package isn't installed, and apt-buildpack
# doesn't run post-install hooks anyway. The Temurin .deb's own
# $JAVA_HOME/lib/security/cacerts is either a broken symlink or an empty
# placeholder after apt-buildpack extraction, so it can't be used either.
#
# Fix: on first task invocation in this container, import every CA from
# the cflinuxfs4 PEM bundle into a JKS keystore under $HOME and point the
# JVM at it. keytool's -importcert wants a single cert per invocation, so
# we split the bundle first. Subsequent task invocations in the same
# container see the keystore already built and skip the work.

TRUSTSTORE="$HOME/truststore.jks"
TRUSTSTORE_PASSWORD="changeit"

if [ ! -s "$TRUSTSTORE" ]; then
  tmp_dir="$(mktemp -d)"
  awk 'BEGIN {n=0} /BEGIN CERTIFICATE/ {n++} {print > sprintf("'"$tmp_dir"'/ca-%04d.pem", n)}' \
    /etc/ssl/certs/ca-certificates.crt
  for pem in "$tmp_dir"/ca-*.pem; do
    [ -s "$pem" ] || continue
    "$JAVA_HOME/bin/keytool" -importcert -noprompt -trustcacerts \
      -alias "$(basename "$pem" .pem)" \
      -file "$pem" \
      -keystore "$TRUSTSTORE" \
      -storepass "$TRUSTSTORE_PASSWORD" >/dev/null 2>&1 || true
  done
  rm -rf "$tmp_dir"
fi

export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASSWORD"
