"""Prints the processing state of the newest Scribbly TestFlight builds."""
import base64, json, os, time, urllib.request
import jwt
key = base64.b64decode(os.environ["ASC_KEY_P8"]).decode()
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1100,
                  "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})
def get(path):
    r = urllib.request.Request("https://api.appstoreconnect.apple.com/v1" + path, headers={"Authorization": "Bearer " + tok})
    return json.loads(urllib.request.urlopen(r).read())
app = get("/apps?filter[bundleId]=com.connor.scribbly")["data"][0]
for b in get(f"/builds?filter[app]={app['id']}&sort=-uploadedDate&limit=4")["data"]:
    a = b["attributes"]; print("BUILD", a["version"], a["processingState"], a["uploadedDate"], "expired" if a.get("expired") else "")
