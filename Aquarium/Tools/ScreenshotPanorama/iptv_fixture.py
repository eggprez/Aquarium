# Fictional channels for the Live TV screenshots; programmes are the demo server's own films.
import datetime as dt, random, json, urllib.request
from PIL import Image, ImageDraw, ImageFont
SP="/private/tmp/claude-501/-Users-scottbindelglass-Documents-FellyJin/3460f0bc-8065-40e4-87df-1e90801c3cf3/scratchpad"
S="https://demo.jellyfin.org/stable"; T=open(SP+"/demo.tok").read().strip()
BASE="http://127.0.0.1:8790"
films={"Night of the Living Dead":("5e6e8380563c5211106652362c5c6843",96),"Dracula":("c002f0f88ee970cce7f138bbc925de64",75),
 "The Great Train Robbery":("788ae1cdf3816e3441e29dd3a96ddfe1",12),"The Great St. Louis Bank Robbery":("b74b4d5de01b4e1a5ce43511c3684ad8",86),
 "Jungle Book":("e16725e2c1c4367ec596cf93c38bbe4f",108),"King Lear":("b07f6514a3e3aa7d8c273458c9cd4c82",110),"Sahara":("70853c7dde5e5759b151cd76876ab6c2",97),
 "Caminandes: Llama Drama":("c541e7545e58b28cd4d0da7aac89d7e8",2),"Caminandes: Gran Dillama":("1056b7d34f0fa0b8ce635428e8b27f37",3),"Caminandes: Llamigos":("c7eb95d14156c803611cf4a78ac469f6",3),
 "The Boy in the Plastic Bubble":("edb39341c5039551a5157e51fe4a3364",93),"Pioneer One":("9bd5926326d651153928e0d11c6ee7cb",45)}
chans=[("101","Reef","#7C4DFF"),("102","Tidewater","#00B8D4"),("103","Lantern","#FFAB00"),("104","Kelp Classics","#00C853"),
       ("105","Nightjar","#D500F9"),("106","Harbour One","#2979FF"),("107","Driftwood","#FF6D00"),("108","Coral","#FF4081"),
       ("109","Lighthouse","#FFD600"),("110","Undertow","#651FFF")]
font=ImageFont.truetype("/System/Library/Fonts/SFNS.ttf",120)
for no,name,col in chans:
    im=Image.new("RGBA",(400,400),(0,0,0,0)); d=ImageDraw.Draw(im)
    d.rounded_rectangle([0,0,399,399],90,fill=col)
    ini="".join(w[0] for w in name.split())[:2]
    d.text((200,200),ini,font=font,fill="white",anchor="mm"); im.save(f"{SP}/iptv/logos/{no}.png")
m3u=["#EXTM3U"]
for no,name,col in chans:
    m3u.append(f'#EXTINF:-1 tvg-id="ch{no}" tvg-chno="{no}" tvg-name="{name}" tvg-logo="{BASE}/logos/{no}.png" group-title="Aquarium",{name}')
    fid=films["Caminandes: Llama Drama"][0]
    m3u.append(f"{S}/Videos/{fid}/stream.mp4?static=true&api_key={T}")
open(SP+"/iptv/channels.m3u","w").write("\n".join(m3u)+"\n")
now=dt.datetime.now(dt.timezone.utc).replace(minute=0,second=0,microsecond=0)-dt.timedelta(hours=2)
f=lambda t:t.strftime("%Y%m%d%H%M%S +0000")
random.seed(7); names=list(films)
x=['<?xml version="1.0" encoding="UTF-8"?>','<tv generator-info-name="aquarium-shots">']
for no,name,col in chans: x.append(f'<channel id="ch{no}"><display-name>{name}</display-name><icon src="{BASE}/logos/{no}.png"/></channel>')
def overview(fid):
    r=urllib.request.Request(f"{S}/Items/{fid}?api_key={T}"); 
    try: return json.load(urllib.request.urlopen(r,timeout=20)).get("Overview","")
    except Exception: return ""
ov={n:overview(films[n][0]) for n in names}
esc=lambda s:s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
for no,name,col in chans:
    t=now+dt.timedelta(minutes=random.choice([0,15,30,45])-60)
    while t<now+dt.timedelta(hours=30):
        n=random.choice(names); mins=random.choice([30,30,30,60,60,90])
        e=t+dt.timedelta(minutes=mins)
        x.append(f'<programme start="{f(t)}" stop="{f(e)}" channel="ch{no}"><title>{esc(n)}</title><desc>{esc(ov[n])}</desc>'
                 f'<icon src="{S}/Items/{films[n][0]}/Images/Primary?maxWidth=600"/></programme>'); t=e
x.append("</tv>"); open(SP+"/iptv/guide.xml","w").write("\n".join(x))
