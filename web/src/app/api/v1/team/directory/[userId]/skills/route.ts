import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { data, type SkillInput } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ userId: string }> };
const KEY_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * The full list of a person's skills: body { "skills": [ { key, level? } ] }, the level for a
 * scaled dimension only. What is not in it ends; a changed level ends the row and starts a new
 * one. Needs skills.manage besides the right to manage the person (403); a level outside the
 * scale is 400; an unknown skill 404.
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const userId = uuidParam((await params).userId, "userId");
    const b = await jsonBody(request);
    const raw = b.skills;
    if (!Array.isArray(raw) || raw.length > 200) throw new ApiError(400, "invalid_skills", "skills must be an array of { key, level }");
    const skills: SkillInput[] = raw.map((x, i) => {
      if (!x || typeof x !== "object" || Array.isArray(x)) throw new ApiError(400, "invalid_skills", `skill ${i + 1} must be an object`);
      const { key, level } = x as Record<string, unknown>;
      if (typeof key !== "string" || !KEY_RE.test(key)) throw new ApiError(400, "invalid_skills", `skill ${i + 1}: key must be a skill key`);
      if (level === undefined || level === null) return { key };
      if (typeof level !== "number" || !Number.isInteger(level) || level < 1 || level > 9) {
        throw new ApiError(400, "invalid_skills", `skill ${i + 1}: level must be a whole number from 1 to 9`);
      }
      return { key, level };
    });
    await data().setPersonSkills(me, userId, skills);
    return ok((await data().listDirectory(me)).find((p) => p.userId === userId) ?? null);
  });
}
