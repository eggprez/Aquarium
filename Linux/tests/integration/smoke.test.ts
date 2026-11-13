import { describe, expect, it } from "vitest";
import { qa, qaApi } from "../helpers/qa";

describe.skipIf(!qa)("QA server: bridge smoke", () => {
  it("signs the api module in and reads the user's views", async () => {
    const api = await qaApi();
    expect(api.getSession()?.userId).toBe(qa!.userId);
    const views = await api.api(`/UserViews?userId=${qa!.userId}`);
    expect(Array.isArray(views.Items)).toBe(true);
    expect(views.Items.length).toBeGreaterThan(0);
  });
});
