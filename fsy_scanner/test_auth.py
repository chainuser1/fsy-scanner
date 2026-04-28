import jwt
import requests
import time

# Read the private key from .env
with open('assets/.env', 'r') as f:
    env_content = f.read()

# Parse the private key
for line in env_content.split('\n'):
    if line.startswith('GOOGLE_SERVICE_ACCOUNT_EMAIL='):
        email = line.split('=', 1)[1].strip()
    if line.startswith('GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY='):
        raw_key = line.split('=', 1)[1].strip()
        # Replace literal \n with actual newlines
        private_key = raw_key.replace('\\n', '\n')

print(f"Email: {email}")
print(f"Key starts with: {private_key[:50]}...")

# Create JWT
now = int(time.time())
payload = {
    'iss': email,
    'sub': email,
    'scope': 'https://www.googleapis.com/auth/spreadsheets',
    'aud': 'https://oauth2.googleapis.com/token',
    'iat': now,
    'exp': now + 3600,
}

signed_jwt = jwt.encode(payload, private_key, algorithm='RS256')

# Exchange for access token
response = requests.post('https://oauth2.googleapis.com/token', data={
    'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
    'assertion': signed_jwt,
})

print(f"\nToken response: {response.status_code}")
print(response.text)

if response.status_code == 200:
    token = response.json()['access_token']
    print(f"\n✅ Got access token: {token[:20]}...")
    
    # Save token for curl
    with open('/tmp/fsy_token.txt', 'w') as f:
        f.write(token)
    print("Token saved to /tmp/fsy_token.txt")
else:
    print("\n❌ Failed to get token")
