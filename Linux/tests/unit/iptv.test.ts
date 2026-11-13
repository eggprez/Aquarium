// src/iptv.ts: the custom Live TV source (an M3U playlist plus an XMLTV guide).
import { beforeEach, describe, expect, it, vi } from "vitest";
import { flush, invokeCalls, onInvoke, signIn } from "../helpers/tauri";
import { deferred, serveSources, xmltvStamp } from "../helpers/small-modules";

type Iptv = typeof import("../../src/iptv");
let iptv: Iptv;

beforeEach(async () => {
  vi.resetModules();
  iptv = await import("../../src/iptv");
});

const M3U = "http://tv.test/list.m3u";
const XML = "http://tv.test/guide.xml";

/** Sign in with a custom source configured. */
async function custom(extra: Record<string, any> = {}): Promise<typeof import("../../src/api")> {
  return signIn({ livetv_source: "custom", livetv_m3u: M3U, livetv_xmltv: XML, ...extra });
}

const PLAYLIST = [
  "#EXTM3U",
  '#EXTINF:-1 tvg-id="one.tv" tvg-chno="101" tvg-logo="http://tv.test/one.png" group-title="News",Channel One',
  "http://tv.test/one.m3u8",
  '#EXTINF:-1 tvg-id="two.tv",Channel Two',
  "http://tv.test/two.m3u8",
].join("\n");

function guide(progs: { ch: string; start: number; stop: number; title: string }[], channels = ""): string {
  return (
    `<?xml version="1.0" encoding="UTF-8"?><tv>${channels}` +
    progs
      .map(
        (p) =>
          `<programme start="${xmltvStamp(p.start)}" stop="${xmltvStamp(p.stop)}" channel="${p.ch}"><title>${p.title}</title></programme>`
      )
      .join("") +
    "</tv>"
  );
}

const H = 3_600_000;
const T0 = Date.UTC(2026, 10, 12, 12, 0, 0);

describe("settings read from the config", () => {
  it("isCustom is true only when the Live TV source is 'custom'", async () => {
    expect(iptv.isCustom()).toBe(false);
    await signIn({ livetv_source: "jellyfin" });
    expect(iptv.isCustom()).toBe(false);
    await signIn({ livetv_source: "custom" });
    expect(iptv.isCustom()).toBe(true);
  });

  it("sourceUrls trims the addresses and answers empty strings when unset", async () => {
    expect(iptv.sourceUrls()).toEqual({ m3u: "", xmltv: "" });
    await signIn({ livetv_m3u: "  http://a/b.m3u \n", livetv_xmltv: null });
    expect(iptv.sourceUrls()).toEqual({ m3u: "http://a/b.m3u", xmltv: "" });
  });

  it("iptvUserAgent falls back to the default when the setting is empty or blank", async () => {
    expect(iptv.iptvUserAgent()).toBe(iptv.DEFAULT_USER_AGENT);
    await signIn({ livetv_user_agent: "   " });
    expect(iptv.iptvUserAgent()).toBe(iptv.DEFAULT_USER_AGENT);
    await signIn({ livetv_user_agent: "  MyPlayer/1.0 " });
    expect(iptv.iptvUserAgent()).toBe("MyPlayer/1.0");
  });

  it("the default User-Agent is a widely deployed player's client string", () => {
    expect(iptv.DEFAULT_USER_AGENT).toMatch(/^VLC\/\d/);
  });

  it.each([
    [undefined, 180],
    [null, 180],
    ["", 180],
    [0, 0],
    ["0", 0],
    [30, 30],
    ["45", 45],
    ["soon", 180],
    [-5, 180],
    [Infinity, 180],
  ])("refreshMinutes(%j) is %d", async (value, want) => {
    await signIn({ livetv_refresh_min: value });
    expect(iptv.refreshMinutes()).toBe(want);
  });

  it("the default refresh interval is three hours", () => {
    expect(iptv.DEFAULT_REFRESH_MIN).toBe(180);
  });
});

describe("parseM3u", () => {
  it("reads name, number, logo, group, guide id and stream of each channel", () => {
    expect(iptv.parseM3u(PLAYLIST)).toEqual([
      {
        Id: "iptv:0",
        Name: "Channel One",
        ChannelNumber: "101",
        LogoUrl: "http://tv.test/one.png",
        StreamUrl: "http://tv.test/one.m3u8",
        Group: "News",
        GuideId: "one.tv",
        Custom: true,
      },
      {
        Id: "iptv:1",
        Name: "Channel Two",
        ChannelNumber: "2",
        LogoUrl: null,
        StreamUrl: "http://tv.test/two.m3u8",
        Group: "",
        GuideId: "two.tv",
        Custom: true,
      },
    ]);
  });

  it("copes with CRLF line endings, blank lines and a byte-order mark", () => {
    const text = "\uFEFF#EXTM3U\r\n\r\n#EXTINF:-1,One\r\n\r\nhttp://a/1\r\n#EXTINF:-1,Two\r\nhttp://a/2\r\n";
    expect(iptv.parseM3u(text).map((c) => [c.Name, c.StreamUrl])).toEqual([
      ["One", "http://a/1"],
      ["Two", "http://a/2"],
    ]);
  });

  it("does not need the #EXTM3U header", () => {
    expect(iptv.parseM3u("#EXTINF:-1,One\nhttp://a/1")).toHaveLength(1);
  });

  it("skips directives and comments between #EXTINF and its stream", () => {
    const text = [
      "#EXTINF:-1,One",
      "#EXTVLCOPT:http-user-agent=Foo",
      "# a comment",
      "#KODIPROP:something=1",
      "http://a/1",
    ].join("\n");
    const [ch] = iptv.parseM3u(text);
    expect(ch.StreamUrl).toBe("http://a/1");
    expect(ch.Name).toBe("One");
  });

  it("uses #EXTGRP as the group until another one, and group-title over it", () => {
    const text = [
      "#EXTGRP: Sport ",
      "#EXTINF:-1,A",
      "http://a/1",
      "#EXTINF:-1,B",
      "http://a/2",
      '#EXTINF:-1 group-title="Films",C',
      "http://a/3",
      "#extgrp:Kids",
      "#EXTINF:-1,D",
      "http://a/4",
    ].join("\n");
    expect(iptv.parseM3u(text).map((c) => c.Group)).toEqual(["Sport", "Sport", "Films", "Kids"]);
  });

  it("gives an empty guide id when tvg-id is missing", () => {
    expect(iptv.parseM3u("#EXTINF:-1,One\nhttp://a/1")[0].GuideId).toBe("");
  });

  it("numbers channels by position when tvg-chno is missing", () => {
    const text = '#EXTINF:-1,A\nhttp://a/1\n#EXTINF:-1 tvg-chno="7.1",B\nhttp://a/2\n#EXTINF:-1,C\nhttp://a/3';
    expect(iptv.parseM3u(text).map((c) => c.ChannelNumber)).toEqual(["1", "7.1", "3"]);
  });

  it("falls back to tvg-name, then to 'Channel', for a missing display name", () => {
    const text = [
      '#EXTINF:-1 tvg-name="From Attribute",',
      "http://a/1",
      '#EXTINF:-1 tvg-name="No Comma At All"',
      "http://a/2",
      "#EXTINF:-1,",
      "http://a/3",
    ].join("\n");
    expect(iptv.parseM3u(text).map((c) => c.Name)).toEqual(["From Attribute", "No Comma At All", "Channel"]);
  });

  it("treats an empty tvg-logo as no logo", () => {
    expect(iptv.parseM3u('#EXTINF:-1 tvg-logo="",One\nhttp://a/1')[0].LogoUrl).toBeNull();
  });

  it("reads attribute names in any case, and the directive in any case", () => {
    const [ch] = iptv.parseM3u('#extinf:-1 TVG-ID="x" Tvg-Logo="http://l/x.png",One\nhttp://a/1');
    expect(ch.GuideId).toBe("x");
    expect(ch.LogoUrl).toBe("http://l/x.png");
  });

  it("keeps a display name that has commas in it", () => {
    expect(iptv.parseM3u("#EXTINF:-1,News, Weather, Sport\nhttp://a/1")[0].Name).toBe("News, Weather, Sport");
  });

  it("keeps apostrophes, equals signs and ampersands inside attribute values", () => {
    const [ch] = iptv.parseM3u(
      '#EXTINF:-1 tvg-id="bob\'s.tv" tvg-logo="http://l/x.png?a=1&b=2" group-title="Bob\'s = best",Bob\'s TV\nhttp://a/1'
    );
    expect(ch.GuideId).toBe("bob's.tv");
    expect(ch.LogoUrl).toBe("http://l/x.png?a=1&b=2");
    expect(ch.Group).toBe("Bob's = best");
    expect(ch.Name).toBe("Bob's TV");
  });

  it("reads the attribute value itself when it has a comma in it", () => {
    const [ch] = iptv.parseM3u('#EXTINF:-1 tvg-id="a" group-title="News, Sport",BBC One\nhttp://a/1');
    expect(ch.Group).toBe("News, Sport");
    expect(ch.GuideId).toBe("a");
  });

  // BUG: parseM3u (src/iptv.ts:111) takes the display name from the FIRST comma
  // on the #EXTINF line. When a quoted attribute value has a comma in it
  // (group-title="News, Sport", tvg-name="Movie, The") the name comes out as
  // the tail of that attribute plus everything after it.
  it.fails("takes the display name from after the attributes when an attribute value has a comma", () => {
    const [ch] = iptv.parseM3u('#EXTINF:-1 tvg-id="a" group-title="News, Sport",BBC One\nhttp://a/1');
    expect(ch.Name).toBe("BBC One");
  });

  it("keeps duplicate channels as separate entries with their own ids", () => {
    const text = '#EXTINF:-1 tvg-id="x",Same\nhttp://a/1\n#EXTINF:-1 tvg-id="x",Same\nhttp://a/1';
    const out = iptv.parseM3u(text);
    expect(out.map((c) => c.Id)).toEqual(["iptv:0", "iptv:1"]);
    expect(out[0].GuideId).toBe(out[1].GuideId);
  });

  it("ignores a stream line that has no #EXTINF before it", () => {
    expect(iptv.parseM3u("http://a/orphan\n#EXTINF:-1,One\nhttp://a/1\nhttp://a/second-orphan")).toEqual([
      expect.objectContaining({ Name: "One", StreamUrl: "http://a/1" }),
    ]);
  });

  it("uses the latest #EXTINF when two come in a row", () => {
    const out = iptv.parseM3u("#EXTINF:-1,Lost\n#EXTINF:-1,Kept\nhttp://a/1");
    expect(out.map((c) => c.Name)).toEqual(["Kept"]);
  });

  it.each(["http", "https", "rtsp", "rtsps", "rtmp", "rtmps", "udp", "rtp", "HTTP", "Https"])(
    "accepts a %s:// stream",
    (scheme) => {
      const url = `${scheme}://host/stream`;
      expect(iptv.parseM3u(`#EXTINF:-1,One\n${url}`)[0].StreamUrl).toBe(url);
    }
  );

  it.each([
    "av://lavfi:testsrc",
    "edl://file.mkv",
    "/etc/passwd",
    "file:///etc/passwd",
    "C:\\videos\\a.mkv",
    "memory://x",
    "javascript:alert(1)",
    "ftp://host/file",
    "relative/path.ts",
    " -- http://not-first",
  ])("drops a channel whose stream is %j (regression: playlists must not reach mpv's other protocols)", (target) => {
    expect(iptv.parseM3u(`#EXTINF:-1,Bad\n${target}`)).toEqual([]);
  });

  it("keeps ids and positional numbers contiguous after a dropped channel, and does not pair its #EXTINF with a later url", () => {
    const text = [
      "#EXTINF:-1,Good 1",
      "http://a/1",
      "#EXTINF:-1,Bad",
      "edl://x",
      "http://a/not-bads-stream",
      "#EXTINF:-1,Good 2",
      "http://a/2",
    ].join("\n");
    expect(iptv.parseM3u(text).map((c) => [c.Id, c.ChannelNumber, c.Name, c.StreamUrl])).toEqual([
      ["iptv:0", "1", "Good 1", "http://a/1"],
      ["iptv:1", "2", "Good 2", "http://a/2"],
    ]);
  });

  it.each(["", "   \n\n", "not a playlist", "<html><body>404</body></html>", "\u0000\u0001\u0002", "#EXTM3U\n#EXTINF:-1,Only a name"])(
    "gives no channels for %j",
    (text) => {
      expect(iptv.parseM3u(text)).toEqual([]);
    }
  );

  it("parses a very large playlist", () => {
    const lines = ["#EXTM3U"];
    for (let i = 0; i < 20_000; i++) {
      lines.push(`#EXTINF:-1 tvg-id="ch${i}" tvg-logo="http://l/${i}.png" group-title="G${i % 50}",Channel ${i}`);
      lines.push(`http://host/${i}.ts`);
    }
    const out = iptv.parseM3u(lines.join("\n"));
    expect(out).toHaveLength(20_000);
    expect(out[19_999]).toMatchObject({ Id: "iptv:19999", Name: "Channel 19999", GuideId: "ch19999", ChannelNumber: "20000" });
  });
});

describe("xmltvTime", () => {
  it("reads a UTC time", () => {
    expect(iptv.xmltvTime("20260817183000 +0000")).toBe(Date.UTC(2026, 7, 17, 18, 30, 0));
  });

  it.each([
    ["20260817183000 +0100", Date.UTC(2026, 7, 17, 17, 30, 0)],
    ["20260817183000 -0500", Date.UTC(2026, 7, 17, 23, 30, 0)],
    ["20260817183000 +0530", Date.UTC(2026, 7, 17, 13, 0, 0)],
    ["20260817183000 +05:30", Date.UTC(2026, 7, 17, 13, 0, 0)],
    ["20260817183000+0100", Date.UTC(2026, 7, 17, 17, 30, 0)],
    ["20260817183000 -0000", Date.UTC(2026, 7, 17, 18, 30, 0)],
    ["20260817183045 +0000", Date.UTC(2026, 7, 17, 18, 30, 45)],
    ["  20260817183000 +0100  ", Date.UTC(2026, 7, 17, 17, 30, 0)],
  ])("applies the offset in %j", (raw, want) => {
    expect(iptv.xmltvTime(raw)).toBe(want);
  });

  it("lets an offset carry the time across midnight and a year end", () => {
    expect(iptv.xmltvTime("20260101003000 +0100")).toBe(Date.UTC(2025, 11, 31, 23, 30, 0));
    expect(iptv.xmltvTime("20261231233000 -0200")).toBe(Date.UTC(2027, 0, 1, 1, 30, 0));
  });

  it("reads a time with no seconds", () => {
    expect(iptv.xmltvTime("202608171830 +0000")).toBe(Date.UTC(2026, 7, 17, 18, 30, 0));
  });

  it("treats a time with no offset as local time", () => {
    expect(iptv.xmltvTime("20260817183000")).toBe(new Date(2026, 7, 17, 18, 30, 0).getTime());
    expect(iptv.xmltvTime("202608171830")).toBe(new Date(2026, 7, 17, 18, 30, 0).getTime());
  });

  it.each(["", "   ", "tomorrow", "2026-08-17T18:30:00Z", "20260817", "2026", null, undefined])(
    "answers NaN for %j rather than a wrong time",
    (raw) => {
      expect(iptv.xmltvTime(raw as any)).toBeNaN();
    }
  );
});

describe("parseXmltv", () => {
  it("reads channel names and icons, and programmes by channel id", () => {
    const xml = `<?xml version="1.0"?>
      <tv>
        <channel id="one.tv"><display-name> Channel One </display-name><icon src=" http://l/one.png "/></channel>
        <channel id="two.tv"><display-name>Channel Two</display-name></channel>
        <programme start="20261112120000 +0000" stop="20261112130000 +0000" channel="one.tv">
          <title> The News </title><sub-title>Evening edition</sub-title><desc>Today's stories.</desc>
        </programme>
        <programme start="20261112130000 +0000" stop="20261112140000 +0000" channel="one.tv"><title>Weather</title></programme>
        <programme start="20261112120000 +0000" stop="20261112140000 +0000" channel="two.tv"><title>Film</title></programme>
      </tv>`;
    const r = iptv.parseXmltv(xml);
    expect([...r.names]).toEqual([
      ["one.tv", "Channel One"],
      ["two.tv", "Channel Two"],
    ]);
    expect([...r.icons]).toEqual([["one.tv", "http://l/one.png"]]);
    expect(r.programs.get("one.tv")).toEqual([
      {
        ChannelId: "one.tv",
        Name: "The News",
        Overview: "Today's stories.",
        EpisodeTitle: "Evening edition",
        StartDate: "2026-11-12T12:00:00.000Z",
        EndDate: "2026-11-12T13:00:00.000Z",
      },
      {
        ChannelId: "one.tv",
        Name: "Weather",
        Overview: "",
        EpisodeTitle: "",
        StartDate: "2026-11-12T13:00:00.000Z",
        EndDate: "2026-11-12T14:00:00.000Z",
      },
    ]);
    expect(r.programs.get("two.tv")).toHaveLength(1);
  });

  it("names an untitled programme 'Programme'", () => {
    const r = iptv.parseXmltv('<tv><programme start="20261112120000 +0000" stop="20261112130000 +0000" channel="a"/></tv>');
    expect(r.programs.get("a")![0].Name).toBe("Programme");
  });

  it("decodes XML entities and takes the first of several titles", () => {
    const r = iptv.parseXmltv(
      '<tv><programme start="20261112120000 +0000" stop="20261112130000 +0000" channel="a">' +
        '<title lang="en">Tom &amp; Jerry &lt;3</title><title lang="fr">Tom et Jerry</title></programme></tv>'
    );
    expect(r.programs.get("a")![0].Name).toBe("Tom & Jerry <3");
  });

  it("converts programme times with offsets to UTC", () => {
    const r = iptv.parseXmltv('<tv><programme start="20261112200000 +0100" stop="20261112210000 +0100" channel="a"><title>X</title></programme></tv>');
    expect(r.programs.get("a")![0]).toMatchObject({
      StartDate: "2026-11-12T19:00:00.000Z",
      EndDate: "2026-11-12T20:00:00.000Z",
    });
  });

  it("keeps a programme that crosses midnight as one entry", () => {
    const r = iptv.parseXmltv('<tv><programme start="20261112233000 +0000" stop="20261113003000 +0000" channel="a"><title>Late</title></programme></tv>');
    expect(r.programs.get("a")).toEqual([
      expect.objectContaining({ StartDate: "2026-11-12T23:30:00.000Z", EndDate: "2026-11-13T00:30:00.000Z" }),
    ]);
  });

  it("keeps overlapping programmes on one channel, in document order", () => {
    const r = iptv.parseXmltv(
      "<tv>" +
        '<programme start="20261112120000 +0000" stop="20261112130000 +0000" channel="a"><title>First</title></programme>' +
        '<programme start="20261112123000 +0000" stop="20261112133000 +0000" channel="a"><title>Overlaps</title></programme>' +
        "</tv>"
    );
    expect(r.programs.get("a")!.map((p) => p.Name)).toEqual(["First", "Overlaps"]);
  });

  it("skips programmes with no channel, an unreadable time, no stop, or a stop not after the start", () => {
    const r = iptv.parseXmltv(
      "<tv>" +
        '<programme start="20261112120000 +0000" stop="20261112130000 +0000"><title>No channel</title></programme>' +
        '<programme start="noon" stop="20261112130000 +0000" channel="a"><title>Bad start</title></programme>' +
        '<programme start="20261112120000 +0000" channel="a"><title>No stop</title></programme>' +
        '<programme start="20261112120000 +0000" stop="20261112120000 +0000" channel="a"><title>Zero length</title></programme>' +
        '<programme start="20261112130000 +0000" stop="20261112120000 +0000" channel="a"><title>Backwards</title></programme>' +
        '<programme start="20261112120000 +0000" stop="20261112130000 +0000" channel="a"><title>Good</title></programme>' +
        "</tv>"
    );
    expect([...r.programs.keys()]).toEqual(["a"]);
    expect(r.programs.get("a")!.map((p) => p.Name)).toEqual(["Good"]);
  });

  it("skips channels with no id, and leaves out names and icons that are empty", () => {
    const r = iptv.parseXmltv(
      '<tv><channel><display-name>Nameless id</display-name></channel>' +
        '<channel id="a"><display-name>  </display-name><icon src=""/></channel>' +
        '<channel id="b"><icon src="http://l/b.png"/></channel></tv>'
    );
    expect([...r.names]).toEqual([]);
    expect([...r.icons]).toEqual([["b", "http://l/b.png"]]);
  });

  it("takes a channel's first display name", () => {
    const r = iptv.parseXmltv('<tv><channel id="a"><display-name>BBC One</display-name><display-name>101</display-name></channel></tv>');
    expect(r.names.get("a")).toBe("BBC One");
  });

  it.each(["", "this is not xml", "<tv><programme></tv>", "<tv>", "\u0000\u0001"])(
    "refuses %j as not valid XML",
    (text) => {
      expect(() => iptv.parseXmltv(text)).toThrow("That XMLTV file isn't valid XML");
    }
  );

  it("gives empty maps for a guide with nothing in it, or another kind of XML document", () => {
    for (const text of ["<tv/>", "<rss><channel><title>News</title></channel></rss>"]) {
      const r = iptv.parseXmltv(text);
      expect(r.programs.size).toBe(0);
      expect(r.names.size).toBe(0);
      expect(r.icons.size).toBe(0);
    }
  });

  it("parses a very large guide", () => {
    const parts = ["<tv>"];
    for (let c = 0; c < 50; c++) parts.push(`<channel id="c${c}"><display-name>Channel ${c}</display-name></channel>`);
    for (let c = 0; c < 50; c++) {
      for (let h = 0; h < 200; h++) {
        parts.push(
          `<programme start="${xmltvStamp(T0 + h * H)}" stop="${xmltvStamp(T0 + (h + 1) * H)}" channel="c${c}"><title>P${h}</title><desc>Text</desc></programme>`
        );
      }
    }
    parts.push("</tv>");
    const r = iptv.parseXmltv(parts.join(""));
    expect(r.names.size).toBe(50);
    expect(r.programs.size).toBe(50);
    expect(r.programs.get("c49")).toHaveLength(200);
    expect(r.programs.get("c49")![199].Name).toBe("P199");
  }, 60_000); // jsdom parses 10,000 programmes in about 3 s alone, far longer under a full parallel run
});

describe("load", () => {
  it("fetches the playlist and guide through fetch_source with the configured User-Agent", async () => {
    await custom({ livetv_user_agent: "Agent/9" });
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    const r = await iptv.load();
    expect(seen.urls).toEqual([M3U, XML]);
    expect(seen.agents).toEqual(["Agent/9", "Agent/9"]);
    expect(r.channels).toHaveLength(2);
  });

  it("sends the default User-Agent when none is set", async () => {
    await custom();
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    await iptv.load();
    expect(seen.agents).toEqual([iptv.DEFAULT_USER_AGENT, iptv.DEFAULT_USER_AGENT]);
  });

  it("does not ask for a guide when no XMLTV address is set", async () => {
    await custom({ livetv_xmltv: "" });
    const seen = serveSources({ [M3U]: PLAYLIST });
    const r = await iptv.load();
    expect(seen.urls).toEqual([M3U]);
    expect(r.programs.size).toBe(0);
    expect(r.matched).toBe(0);
  });

  it("refuses to load with no playlist address, without a request", async () => {
    await signIn({ livetv_source: "custom" });
    const seen = serveSources({});
    await expect(iptv.load()).rejects.toThrow("No M3U playlist address is set");
    expect(seen.urls).toEqual([]);
  });

  it("refuses a playlist with no channels in it", async () => {
    await custom();
    serveSources({ [M3U]: "<html>login required</html>", [XML]: guide([]) });
    await expect(iptv.load()).rejects.toThrow("That playlist has no channels in it");
  });

  it("passes on a failed playlist fetch, and tries again on the next call", async () => {
    await custom();
    let fail = true;
    serveSources({
      [M3U]: () => {
        if (fail) throw new Error("connection refused");
        return PLAYLIST;
      },
      [XML]: guide([]),
    });
    await expect(iptv.load()).rejects.toThrow("connection refused");
    expect(iptv.lastRead()).toBeNull();
    fail = false;
    expect((await iptv.load()).channels).toHaveLength(2);
  });

  it("keeps the channel list when the guide is broken, and logs why (regression: a broken guide must not cost the channels)", async () => {
    await custom();
    serveSources({ [M3U]: PLAYLIST, [XML]: "<tv><oops" });
    const r = await iptv.load();
    expect(r.channels).toHaveLength(2);
    expect(r.programs.size).toBe(0);
    expect(r.matched).toBe(0);
    const logs = invokeCalls("ui_log").map((c) => c.args.msg);
    expect(logs).toEqual([expect.stringContaining("iptv: guide failed: That XMLTV file isn't valid XML")]);
  });

  it("keeps the channel list when the guide cannot be fetched", async () => {
    await custom();
    serveSources({ [M3U]: PLAYLIST, [XML]: new Error("404") });
    const r = await iptv.load();
    expect(r.channels).toHaveLength(2);
    expect(invokeCalls("ui_log").map((c) => c.args.msg)).toEqual(["iptv: guide failed: 404"]);
  });

  it("reads once and answers later calls from memory", async () => {
    await custom();
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    const a = await iptv.load();
    const b = await iptv.load();
    expect(b).toBe(a);
    expect(seen.urls).toHaveLength(2);
  });

  it("shares one fetch between concurrent callers", async () => {
    await custom();
    const gate = deferred<string>();
    const seen = serveSources({ [M3U]: () => gate.promise, [XML]: guide([]) });
    const a = iptv.load();
    const b = iptv.load();
    const c = iptv.getChannels();
    gate.resolve(PLAYLIST);
    expect(await a).toBe(await b);
    expect(await c).toBe((await a).channels);
    expect(seen.urls).toEqual([M3U, XML]);
  });

  it("reads again when forced, even with a fresh copy in memory", async () => {
    await custom();
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    const a = await iptv.load();
    const b = await iptv.load(true);
    expect(b).not.toBe(a);
    expect(seen.urls).toEqual([M3U, XML, M3U, XML]);
  });

  it("starts a new read when forced while another is in flight", async () => {
    await custom({ livetv_xmltv: "" });
    const first = deferred<string>();
    let n = 0;
    serveSources({ [M3U]: () => (n++ === 0 ? first.promise : PLAYLIST) });
    const a = iptv.load();
    const b = iptv.load(true);
    first.resolve("#EXTINF:-1,Old\nhttp://a/old");
    expect((await b).channels).toHaveLength(2);
    expect((await a).channels).toHaveLength(1);
    expect(n).toBe(2);
  });

  it("reads again when either address changes", async () => {
    const api = await custom();
    const other = "http://tv.test/other.m3u";
    const otherXml = "http://tv.test/other.xml";
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]), [other]: "#EXTINF:-1,Solo\nhttp://a/solo", [otherXml]: guide([]) });
    await iptv.load();
    expect(iptv.isDue()).toBe(false);

    await api.saveConfig({ livetv_m3u: other });
    expect(iptv.isDue()).toBe(true);
    expect((await iptv.load()).channels.map((c) => c.Name)).toEqual(["Solo"]);
    expect(iptv.isDue()).toBe(false);

    await api.saveConfig({ livetv_xmltv: otherXml });
    expect(iptv.isDue()).toBe(true);
    await iptv.load();
    expect(seen.urls).toEqual([M3U, XML, other, XML, other, otherXml]);
  });

  it("reads again once the refresh interval has passed, and not before", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    await custom({ livetv_refresh_min: 30 });
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    await iptv.load();
    expect(iptv.lastRead()!.at).toBe(T0);

    vi.setSystemTime(T0 + 30 * 60_000);
    expect(iptv.isDue()).toBe(false);
    await iptv.load();
    expect(seen.urls).toHaveLength(2);

    vi.setSystemTime(T0 + 30 * 60_000 + 1);
    expect(iptv.isDue()).toBe(true);
    await iptv.load();
    expect(seen.urls).toHaveLength(4);
    expect(iptv.lastRead()!.at).toBe(T0 + 30 * 60_000 + 1);
  });

  it("uses the three-hour default interval when none is set", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    await custom();
    serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    await iptv.load();
    vi.setSystemTime(T0 + 3 * H);
    expect(iptv.isDue()).toBe(false);
    vi.setSystemTime(T0 + 3 * H + 1);
    expect(iptv.isDue()).toBe(true);
  });

  it("never ages out with the interval at 0", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    await custom({ livetv_refresh_min: 0 });
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    await iptv.load();
    vi.setSystemTime(T0 + 365 * 24 * H);
    expect(iptv.isDue()).toBe(false);
    await iptv.load();
    expect(seen.urls).toHaveLength(2);
  });

  it("invalidate makes the next load read again", async () => {
    await custom();
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    expect(iptv.isDue()).toBe(true);
    await iptv.load();
    iptv.invalidate();
    expect(iptv.isDue()).toBe(true);
    expect(iptv.lastRead()).toBeNull();
    await iptv.load();
    expect(seen.urls).toHaveLength(4);
  });
});

describe("joining the playlist to the guide", () => {
  async function loaded(m3u: string, xml: string): Promise<Awaited<ReturnType<Iptv["load"]>>> {
    await custom();
    serveSources({ [M3U]: m3u, [XML]: xml });
    return iptv.load();
  }
  const prog = (ch: string, title = "Show"): { ch: string; start: number; stop: number; title: string } => ({
    ch,
    start: T0,
    stop: T0 + H,
    title,
  });

  it("joins on tvg-id and rewrites each programme's ChannelId to the playlist channel's Id", async () => {
    const r = await loaded(PLAYLIST, guide([prog("two.tv", "On Two"), prog("one.tv", "On One")]));
    expect(r.matched).toBe(2);
    expect(r.programs.get("iptv:0")).toEqual([expect.objectContaining({ ChannelId: "iptv:0", Name: "On One" })]);
    expect(r.programs.get("iptv:1")).toEqual([expect.objectContaining({ ChannelId: "iptv:1", Name: "On Two" })]);
  });

  it("falls back to the display name, ignoring case, spacing and punctuation, when tvg-id is missing", async () => {
    const r = await loaded(
      "#EXTINF:-1,BBC One HD\nhttp://a/1",
      guide([prog("bbc1.uk")], '<channel id="bbc1.uk"><display-name>bbc-one (hd)</display-name></channel>')
    );
    expect(r.matched).toBe(1);
    expect(r.programs.get("iptv:0")).toHaveLength(1);
  });

  it("falls back to the display name when the playlist's tvg-id matches nothing in the guide", async () => {
    const r = await loaded(
      '#EXTINF:-1 tvg-id="wrong-id",Channel One\nhttp://a/1',
      guide([prog("right-id")], '<channel id="right-id"><display-name>Channel One</display-name></channel>')
    );
    expect(r.matched).toBe(1);
    expect(r.programs.get("iptv:0")![0].ChannelId).toBe("iptv:0");
  });

  it("prefers a tvg-id match over a name match", async () => {
    const r = await loaded(
      '#EXTINF:-1 tvg-id="by-id",Shared Name\nhttp://a/1',
      guide(
        [prog("by-id", "From id"), prog("by-name", "From name")],
        '<channel id="by-name"><display-name>Shared Name</display-name></channel>'
      )
    );
    expect(r.programs.get("iptv:0")!.map((p) => p.Name)).toEqual(["From id"]);
  });

  it("uses the first guide channel when two share a display name", async () => {
    const r = await loaded(
      "#EXTINF:-1,Twin\nhttp://a/1",
      guide(
        [prog("first", "First's"), prog("second", "Second's")],
        '<channel id="first"><display-name>Twin</display-name></channel><channel id="second"><display-name>TWIN</display-name></channel>'
      )
    );
    expect(r.programs.get("iptv:0")!.map((p) => p.Name)).toEqual(["First's"]);
  });

  it("gives duplicate playlist channels their own copy of the same programmes", async () => {
    const r = await loaded(
      '#EXTINF:-1 tvg-id="x",Same\nhttp://a/1\n#EXTINF:-1 tvg-id="x",Same\nhttp://a/2',
      guide([prog("x")])
    );
    expect(r.matched).toBe(2);
    expect(r.programs.get("iptv:0")![0].ChannelId).toBe("iptv:0");
    expect(r.programs.get("iptv:1")![0].ChannelId).toBe("iptv:1");
  });

  it("leaves a channel the guide says nothing about out of the programmes, and out of the matched count", async () => {
    const r = await loaded(PLAYLIST, guide([prog("one.tv")], '<channel id="two.tv"><display-name>Channel Two</display-name></channel>'));
    expect(r.matched).toBe(1);
    expect([...r.programs.keys()]).toEqual(["iptv:0"]);
  });

  it("does not match channels with empty names to each other", async () => {
    const r = await loaded(
      "#EXTINF:-1,***\nhttp://a/1",
      guide([prog("sym")], '<channel id="sym"><display-name>!!!</display-name></channel>')
    );
    expect(r.matched).toBe(0);
  });

  it("uses the guide's icon for a channel with no logo, and keeps a logo the playlist named", async () => {
    const r = await loaded(
      PLAYLIST,
      guide(
        [prog("one.tv"), prog("two.tv")],
        '<channel id="one.tv"><icon src="http://guide/one.png"/></channel><channel id="two.tv"><icon src="http://guide/two.png"/></channel>'
      )
    );
    expect(r.channels[0].LogoUrl).toBe("http://tv.test/one.png");
    expect(r.channels[1].LogoUrl).toBe("http://guide/two.png");
  });

  it("uses the guide's icon even for a channel that has no programmes", async () => {
    const r = await loaded(PLAYLIST, guide([], '<channel id="two.tv"><icon src="http://guide/two.png"/></channel>'));
    expect(r.channels[1].LogoUrl).toBe("http://guide/two.png");
    expect(r.matched).toBe(0);
  });
});

describe("what the views read", () => {
  it("lastRead is null before the first read, then reports the counts and the time", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(T0);
    await custom();
    expect(iptv.lastRead()).toBeNull();
    serveSources({
      [M3U]: PLAYLIST,
      [XML]: guide([
        { ch: "one.tv", start: T0, stop: T0 + H, title: "A" },
        { ch: "one.tv", start: T0 + H, stop: T0 + 2 * H, title: "B" },
        { ch: "nobody", start: T0, stop: T0 + H, title: "Unjoined" },
      ]),
    });
    await iptv.load();
    expect(iptv.lastRead()).toEqual({ at: T0, channels: 2, withLogos: 1, matched: 1, programs: 2 });
  });

  it("describe re-reads the source and reports channels, matched channels and programmes", async () => {
    await custom();
    const seen = serveSources({
      [M3U]: PLAYLIST,
      [XML]: guide([
        { ch: "one.tv", start: T0, stop: T0 + H, title: "A" },
        { ch: "two.tv", start: T0, stop: T0 + H, title: "B" },
        { ch: "two.tv", start: T0 + H, stop: T0 + 2 * H, title: "C" },
      ]),
    });
    await iptv.load();
    expect(await iptv.describe()).toEqual({ channels: 2, matched: 2, programs: 3 });
    expect(seen.urls).toHaveLength(4);
    expect(await iptv.describe(false)).toEqual({ channels: 2, matched: 2, programs: 3 });
    expect(seen.urls).toHaveLength(4);
  });

  it("getChannels hands back the playlist, and re-reads it only when forced", async () => {
    await custom();
    const seen = serveSources({ [M3U]: PLAYLIST, [XML]: guide([]) });
    expect((await iptv.getChannels()).map((c) => c.Name)).toEqual(["Channel One", "Channel Two"]);
    await iptv.getChannels();
    expect(seen.urls).toHaveLength(2);
    await iptv.getChannels(true);
    expect(seen.urls).toHaveLength(4);
  });

  describe("getPrograms", () => {
    async function withGuide(): Promise<void> {
      await custom();
      serveSources({
        [M3U]: PLAYLIST,
        [XML]: guide([
          { ch: "one.tv", start: T0 - H, stop: T0, title: "Ended at the start" },
          { ch: "one.tv", start: T0 - H / 2, stop: T0 + H / 2, title: "Already running" },
          { ch: "one.tv", start: T0 + H / 2, stop: T0 + H, title: "Inside" },
          { ch: "one.tv", start: T0 + (3 * H) / 2, stop: T0 + 3 * H, title: "Runs past the end" },
          { ch: "one.tv", start: T0 + 2 * H, stop: T0 + 3 * H, title: "Starts at the end" },
          { ch: "two.tv", start: T0 - 10 * H, stop: T0 + 10 * H, title: "Covers everything" },
          { ch: "two.tv", start: T0 + H, stop: T0 + H + 60_000, title: "Overlapping the long one" },
        ]),
      });
    }

    it("returns every programme overlapping [from, to), across channels", async () => {
      await withGuide();
      const out = await iptv.getPrograms(new Date(T0), new Date(T0 + 2 * H));
      expect(out.map((p) => p.Name)).toEqual([
        "Already running",
        "Inside",
        "Runs past the end",
        "Covers everything",
        "Overlapping the long one",
      ]);
      expect(new Set(out.map((p) => p.ChannelId))).toEqual(new Set(["iptv:0", "iptv:1"]));
    });

    it("leaves out a programme that ends exactly at the start or starts exactly at the end", async () => {
      await withGuide();
      const names = (await iptv.getPrograms(new Date(T0), new Date(T0 + 2 * H))).map((p) => p.Name);
      expect(names).not.toContain("Ended at the start");
      expect(names).not.toContain("Starts at the end");
    });

    it("finds a programme that crosses midnight from either day", async () => {
      await custom();
      const midnight = Date.UTC(2026, 10, 13, 0, 0, 0);
      serveSources({
        [M3U]: PLAYLIST,
        [XML]: guide([{ ch: "one.tv", start: midnight - H / 2, stop: midnight + H / 2, title: "Late film" }]),
      });
      const before = await iptv.getPrograms(new Date(midnight - 24 * H), new Date(midnight));
      const after = await iptv.getPrograms(new Date(midnight), new Date(midnight + 24 * H));
      expect(before.map((p) => p.Name)).toEqual(["Late film"]);
      expect(after.map((p) => p.Name)).toEqual(["Late film"]);
    });

    it("answers from memory, with no request per call", async () => {
      await withGuide();
      await iptv.getPrograms(new Date(T0), new Date(T0 + H));
      const before = invokeCalls("fetch_source").length;
      await iptv.getPrograms(new Date(T0), new Date(T0 + H));
      await iptv.getPrograms(new Date(T0 + H), new Date(T0 + 2 * H));
      expect(invokeCalls("fetch_source")).toHaveLength(before);
    });

    it("is empty when there is no guide", async () => {
      await custom({ livetv_xmltv: "" });
      serveSources({ [M3U]: PLAYLIST });
      expect(await iptv.getPrograms(new Date(0), new Date(T0 * 2))).toEqual([]);
    });
  });

  it("a guide log failure does not break the load", async () => {
    await custom();
    serveSources({ [M3U]: PLAYLIST, [XML]: "nope" });
    onInvoke("ui_log", () => null);
    await expect(iptv.load()).resolves.toMatchObject({ matched: 0 });
    await flush();
  });
});
