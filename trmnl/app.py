import requests

   def solar_powered_adapter():
        url = "https://api.example.com/solar-adapter"
        response = requests.get(url)
        data = response.json()
        body = data.get('body', '')
        if 'discord' in body.lower() and '#ideas' in body:
            raise ValueError("No solar adapter product found