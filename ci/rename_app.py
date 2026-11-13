"""Sets the App Store Connect app name (all localizations) to NAME."""
import base64, json, os, sys, time, urllib.request, urllib.error
import jwt
NAME = sys.argv[1]
key = base64.b64decode(os.environ["ASC_KEY_P8"]).decode()
tok = jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 1100,
                  "aud": "appstoreconnect-v1"}, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})
def call(m, path, body=None):
    r = urllib.request.Request("https://api.appstoreconnect.apple.com/v1" + path, method=m,
        data=json.dumps(body).encode() if body else None, headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try: return json.loads(urllib.request.urlopen(r).read() or b"{}")
    except urllib.error.HTTPError as e: print(m, path, e.code, e.read()[:500]); raise
app = call("GET", "/apps?filter[bundleId]=com.connor.scribbly")["data"][0]
print("APP", app["attributes"]["name"])
for info in call("GET", f"/apps/{app['id']}/appInfos")["data"]:
    for loc in call("GET", f"/appInfos/{info['id']}/appInfoLocalizations")["data"]:
        if loc["attributes"]["name"] == NAME: print("ALREADY", loc["attributes"]["locale"]); continue
        try:
            call("PATCH", f"/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {"name": NAME}}})
            print("RENAMED", loc["attributes"]["locale"], info["attributes"].get("appStoreState"))
        except Exception: print("SKIPPED (locked)", loc["attributes"]["locale"], info["attributes"].get("appStoreState"))
print("APP NOW", call("GET", f"/apps/{app['id']}")["data"]["attributes"]["name"])
