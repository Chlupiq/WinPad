"""Your Apple certificate as a .p12 file, made without a Mac (Windows PC, Linux).

Signing outside a Mac (rcodesign, the cloud job) takes the certificate with its private
key as a .p12 file. A Mac's Keychain exports one; without a Mac:

1. request: make a private key and a certificate signing request (CSR);
2. at developer.apple.com > Certificates > + > Apple Development, upload the CSR and
   download the certificate (.cer);
3. p12: put the key and that certificate into a .p12 file.

Then make a profile there (Profiles > + > iOS App Development, the app's identifier,
the certificate, the iPad) and download the .mobileprovision. That takes a paid Apple
Developer account: a free one has no certificates page (use a Mac with Xcode there).
"""
import os

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID


class CertError(Exception):
    pass


def request(folder, email, name="WinPad"):
    """Writes FOLDER/winpad-key.pem (keep it) and FOLDER/winpad.certSigningRequest (for Apple).
    Returns the request's path."""
    os.makedirs(folder, exist_ok=True)
    key_path = os.path.join(folder, "winpad-key.pem")
    if os.path.exists(key_path):
        with open(key_path, "rb") as f:
            key = serialization.load_pem_private_key(f.read(), None)
    else:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.EMAIL_ADDRESS, email),
                                    x509.NameAttribute(NameOID.COMMON_NAME, name),
                                    x509.NameAttribute(NameOID.COUNTRY_NAME, "US")]))
           .sign(key, hashes.SHA256()))
    path = os.path.join(folder, "winpad.certSigningRequest")
    with open(path, "wb") as f:
        f.write(csr.public_bytes(serialization.Encoding.PEM))
    return path


def load_certificate(path):
    with open(path, "rb") as f:
        data = f.read()
    try:
        return x509.load_der_x509_certificate(data)
    except ValueError:
        return x509.load_pem_x509_certificate(data)


def make_p12(folder, cer, out, password):
    """Writes OUT: the key from request() with Apple's certificate CER. Returns the certificate's name."""
    key_path = os.path.join(folder, "winpad-key.pem")
    if not os.path.isfile(key_path):
        raise CertError(f"no {key_path}: the .p12 needs the key the request was made with")
    with open(key_path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), None)
    cert = load_certificate(cer)
    if cert.public_key().public_numbers() != key.public_key().public_numbers():
        raise CertError(f"{cer} was not made from this request's key")
    name = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
    name = name[0].value if name else "WinPad"
    # 3DES and SHA-1, as Keychain writes them: what every signer reads.
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder()
           .kdf_rounds(2048)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
           .hmac_hash(hashes.SHA1())
           .build(password.encode()))
    data = pkcs12.serialize_key_and_certificates(name.encode(), key, cert, None, enc)
    with open(out, "wb") as f:
        f.write(data)
    return name
