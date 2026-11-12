"""Makes sure the main app's App Store profile includes Associated Domains
(needed for iPhone Passwords), creating a fresh profile when it doesn't.
Prints the profile name; writes the .mobileprovision to argv[1]."""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error
import jwt  # pyjwt

BUNDLE = "com.connor.scribbly"
NAME = "Scribbly CI AD"
API = "https://api.appstoreconnect.apple.com/v1"
key = base64.b64decode(os.environ["ASC_KEY_P8"]).decode()
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1100,
                  "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        print(f"{method} {path} -> {e.code} {e.read()[:400]!r}", file=sys.stderr); raise

b = call("GET", f"/bundleIds?filter[identifier]={BUNDLE}&include=bundleIdCapabilities&limit=5")
bundle = next(x for x in b["data"] if x["attributes"]["identifier"] == BUNDLE)
caps = [c["attributes"]["capabilityType"] for c in b.get("included", []) if c["type"] == "bundleIdCapabilities"]
print("capabilities:", caps, file=sys.stderr)
if "ASSOCIATED_DOMAINS" not in caps:
    call("POST", "/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
         "attributes": {"capabilityType": "ASSOCIATED_DOMAINS"},
         "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}}}}})
    print("enabled ASSOCIATED_DOMAINS", file=sys.stderr)

# the distribution cert this run signs with
serial = subprocess.check_output(["bash", "-c", "openssl x509 -in /tmp/dist.pem -noout -serial"]).decode().split("=")[1].strip().lstrip("0").upper()
certs = call("GET", "/certificates?limit=50")["data"]
cert = next(c for c in certs if c["attributes"]["serialNumber"].lstrip("0").upper() == serial)

existing = call("GET", f"/profiles?filter[name]={urllib.request.quote(NAME)}&limit=10")["data"]
prof = next((p for p in existing if p["attributes"]["profileState"] == "ACTIVE"), None)
if prof is None:
    prof = call("POST", "/profiles", {"data": {"type": "profiles",
        "attributes": {"name": NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
    print("created profile", prof["id"], file=sys.stderr)
open(sys.argv[1], "wb").write(base64.b64decode(prof["attributes"]["profileContent"]))
print(NAME)
