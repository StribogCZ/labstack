import os
import sys
import json
import base64
import datetime
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

from cryptography import x509
from cryptography.x509.oid import NameOID, ExtensionOID, ExtendedKeyUsageOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("LocalCA")

CA_DIR = "/etc/czertainly-ca"
CA_KEY_PATH = os.path.join(CA_DIR, "ca.key")
CA_CRT_PATH = os.path.join(CA_DIR, "ca.crt")

def init_ca():
    os.makedirs(CA_DIR, exist_ok=True)
    if os.path.exists(CA_KEY_PATH) and os.path.exists(CA_CRT_PATH):
        with open(CA_KEY_PATH, "rb") as f:
            ca_key = serialization.load_pem_private_key(f.read(), password=None)
        with open(CA_CRT_PATH, "rb") as f:
            ca_crt = x509.load_pem_x509_certificate(f.read())
        logger.info("Loaded existing CA certificate and key from %s", CA_DIR)
        return ca_key, ca_crt

    logger.info("Generating new Root CA key and certificate...")
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "CZ"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Lab Local Authority"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Lab Local Root CA"),
    ])
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_crt = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()),
            critical=False,
        )
        .sign(ca_key, hashes.SHA256())
    )

    with open(CA_KEY_PATH, "wb") as f:
        f.write(ca_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ))
    with open(CA_CRT_PATH, "wb") as f:
        f.write(ca_crt.public_bytes(serialization.Encoding.PEM))
    logger.info("Root CA created at %s", CA_DIR)
    return ca_key, ca_crt

CA_KEY, CA_CRT = init_ca()

class CAHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        logger.info("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), format % args))

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        logger.info("GET %s", path)

        if path in ("/v1", "/v1/"):
            response = [{
                "functionGroupCode": "authorityProvider",
                "kinds": ["Local-CA"],
                "endPoints": [
                    {"name": "checkHealth", "context": "/v1/health", "method": "GET", "required": False},
                    {"name": "listSupportedFunctions", "context": "/v1", "method": "GET", "required": False},
                    {"name": "listAttributeDefinitions", "context": "/v1/authorityProvider/{kind}/attributes", "method": "GET", "required": False},
                    {"name": "validateAttributes", "context": "/v1/authorityProvider/{kind}/attributes/validate", "method": "POST", "required": False},
                    {"name": "listAuthorityInstances", "context": "/v1/authorityProvider/authorities", "method": "GET", "required": False},
                    {"name": "createAuthorityInstance", "context": "/v1/authorityProvider/authorities", "method": "POST", "required": False},
                    {"name": "getAuthorityInstance", "context": "/v1/authorityProvider/authorities/{uuid}", "method": "GET", "required": False},
                    {"name": "updateAuthorityInstance", "context": "/v1/authorityProvider/authorities/{uuid}", "method": "POST", "required": False},
                    {"name": "removeAuthorityInstance", "context": "/v1/authorityProvider/authorities/{uuid}", "method": "DELETE", "required": False},
                    {"name": "listRAProfileAttributes", "context": "/v1/authorityProvider/authorities/{uuid}/raProfile/attributes", "method": "GET", "required": False},
                    {"name": "listIssueCertificateAttributes", "context": "/v2/authorityProvider/authorities/{uuid}/certificates/issue/attributes", "method": "GET", "required": False},
                    {"name": "validateIssueCertificateAttributes", "context": "/v2/authorityProvider/authorities/{uuid}/certificates/issue/attributes/validate", "method": "POST", "required": False},
                    {"name": "issueCertificate", "context": "/v2/authorityProvider/authorities/{uuid}/certificates/issue", "method": "POST", "required": False},
                    {"name": "renewCertificate", "context": "/v2/authorityProvider/authorities/{uuid}/certificates/renew", "method": "POST", "required": False},
                    {"name": "revokeCertificate", "context": "/v2/authorityProvider/authorities/{uuid}/certificates/revoke", "method": "POST", "required": False}
                ]
            }]
            return self._send_json(response)

        if path in ("/v1/health", "/v2/health", "/health"):
            return self._send_json({"status": "ok"})

        if "/attributes" in path:
            return self._send_json([])

        if path == "/v1/authorityProvider/authorities":
            return self._send_json([{"uuid": "local-ca-1", "name": "lab-ca", "attributes": []}])

        if "/v1/authorityProvider/authorities/" in path:
            return self._send_json({"uuid": "local-ca-1", "name": "lab-ca", "attributes": []})

        if path == "/ca.crt":
            with open(CA_CRT_PATH, "rb") as f:
                crt_bytes = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "application/x-x509-ca-cert")
            self.send_header("Content-Length", str(len(crt_bytes)))
            self.end_headers()
            self.wfile.write(crt_bytes)
            return

        self._send_json({"error": "Not Found", "path": path}, status=404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length > 0 else b"{}"
        logger.info("POST %s, body length: %d", path, len(body))

        if "/validate" in path:
            return self._send_json(True)

        if path == "/v1/authorityProvider/authorities":
            return self._send_json({"uuid": "local-ca-1", "name": "lab-ca", "attributes": []})

        if "/certificates/issue" in path:
            try:
                payload = json.loads(body.decode("utf-8"))
                req_raw = payload.get("request", "")
                logger.info("Received certificate issue request, length: %d", len(req_raw))

                csr_bytes = None
                # Try decoding base64
                try:
                    decoded = base64.b64decode(req_raw)
                    csr_bytes = decoded
                except Exception:
                    csr_bytes = req_raw.encode("utf-8")

                csr = None
                try:
                    csr = x509.load_der_x509_csr(csr_bytes)
                except Exception:
                    try:
                        csr = x509.load_pem_x509_csr(csr_bytes)
                    except Exception:
                        csr = x509.load_pem_x509_csr(req_raw.encode("utf-8"))

                now = datetime.datetime.now(datetime.timezone.utc)
                builder = (
                    x509.CertificateBuilder()
                    .subject_name(csr.subject)
                    .issuer_name(CA_CRT.subject)
                    .public_key(csr.public_key())
                    .serial_number(x509.random_serial_number())
                    .not_valid_before(now - datetime.timedelta(hours=1))
                    .not_valid_after(now + datetime.timedelta(days=90))
                    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                    .add_extension(
                        x509.KeyUsage(
                            digital_signature=True,
                            content_commitment=False,
                            key_encipherment=True,
                            data_encipherment=False,
                            key_agreement=False,
                            key_cert_sign=False,
                            crl_sign=False,
                            encipher_only=False,
                            decipher_only=False,
                        ),
                        critical=True,
                    )
                    .add_extension(
                        x509.ExtendedKeyUsage([
                            ExtendedKeyUsageOID.SERVER_AUTH,
                            ExtendedKeyUsageOID.CLIENT_AUTH,
                        ]),
                        critical=False,
                    )
                    .add_extension(
                        x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),
                        critical=False,
                    )
                    .add_extension(
                        x509.AuthorityKeyIdentifier.from_issuer_public_key(CA_KEY.public_key()),
                        critical=False,
                    )
                )

                # Copy SAN extension if present in CSR
                try:
                    san_ext = csr.extensions.get_extension_for_oid(ExtensionOID.SUBJECT_ALTERNATIVE_NAME)
                    builder = builder.add_extension(san_ext.value, critical=False)
                except Exception:
                    # If not in extensions, add commonName as SAN DNSName
                    for attr in csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME):
                        val = attr.value
                        builder = builder.add_extension(
                            x509.SubjectAlternativeName([x509.DNSName(val)]),
                            critical=False,
                        )
                        break

                cert = builder.sign(CA_KEY, hashes.SHA256())
                der_bytes = cert.public_bytes(serialization.Encoding.DER)
                b64_data = base64.b64encode(der_bytes).decode("ascii")

                logger.info("Successfully issued certificate for %s", csr.subject)
                response = {
                    "certificateData": b64_data,
                    "uuid": None,
                    "meta": None,
                    "certificateType": "X.509"
                }
                return self._send_json(response)
            except Exception as e:
                logger.exception("Error issuing certificate: %s", e)
                return self._send_json({"error": str(e)}, status=500)

        self._send_json({"status": "ok"})

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8888))
    server = HTTPServer(("0.0.0.0", port), CAHandler)
    logger.info("Starting Local CA Provider on 0.0.0.0:%d", port)
    server.serve_forever()
