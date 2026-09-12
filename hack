import { z } from "zod";

// ==========================================
// 1. DATA MODELS & TYPES
// ==========================================

export interface UserProfile {
  id: string;
  name: string;
  email: string;
  deviceHash: string;
  bio: string;
  skillsOffered: string[];
  skillsDesired: string[];
  rating: number; // 0.0 - 5.0
  feedbackScore: number; // 0 - 100
  activeTradeCount: number; // For bottleneck load balancing
  availabilityHoursPerWeek: number;
}

export type MatchType = "DIRECT_1_TO_1" | "LOOP_3_WAY";

export interface MatchRecommendation {
  matchType: MatchType;
  compatibilityScore: number; // 0 - 100
  explanation: string;
  tradeChain: {
    fromUser: string;
    toUser: string;
    skill: string;
  }[];
}

export interface ValidationResult {
  isValid: boolean;
  errors: string[];
  requiresAdminReview: boolean;
  suspectedDuplicateOfUserId?: string;
}

export interface PostSessionSummary {
  keyTakeaways: string[];
  actionableHomework: string[];
  recommendedFollowUps: string[];
}

export interface EscalationTicket {
  ticketId: string;
  userId: string;
  issueType: "PROFILE_INTEGRITY" | "FRAUD_SUSPICION" | "UNRESOLVED_CONFLICT" | "SYSTEM_ERROR";
  description: string;
  metadata: Record<string, unknown>;
  routedTo: string;
  status: "OPEN" | "ROUTED";
  createdAt: string;
}

// ==========================================
// 2. PROFILE VALIDATION & ACCOUNT INTEGRITY
// ==========================================

export class ProfileIntegrityService {
  /**
   * Rule 1: Prevent listing exact same skill in offered & desired
   * Rule 2: Multi-account fraud detection (device hash, email, bio similarity)
   */
  static validateProfile(newUser: UserProfile, existingUsers: UserProfile[]): ValidationResult {
    const errors: string[] = [];
    let requiresAdminReview = false;
    let suspectedDuplicateOfUserId: string | undefined;

    // Normalize strings for comparison
    const offeredNormalized = new Set(newUser.skillsOffered.map((s) => s.trim().toLowerCase()));
    const desiredNormalized = new Set(newUser.skillsDesired.map((s) => s.trim().toLowerCase()));

    // 1. Check for overlapping skills
    for (const skill of offeredNormalized) {
      if (desiredNormalized.has(skill)) {
        errors.push(
          `Conflict detected for skill "${skill}". You cannot offer and request the exact same skill without specifying a sub-discipline or proficiency level difference.`
        );
      }
    }

    // 2. Check for multi-account / duplicate signatures
    for (const existing of existingUsers) {
      if (existing.id === newUser.id) continue;

      const sameDevice = existing.deviceHash && existing.deviceHash === newUser.deviceHash;
      const sameEmail = existing.email.toLowerCase() === newUser.email.toLowerCase();
      const identicalBio =
        existing.bio.trim().length > 30 &&
        existing.bio.trim().toLowerCase() === newUser.bio.trim().toLowerCase();

      if (sameDevice || sameEmail || identicalBio) {
        requiresAdminReview = true;
        suspectedDuplicateOfUserId = existing.id;
        errors.push(
          `Integrity alert: Potential duplicate account associated with user ${existing.id}. Held for administrative verification.`
        );
        break;
      }
    }

    return {
      isValid: errors.length === 0,
      errors,
      requiresAdminReview,
      suspectedDuplicateOfUserId,
    };
  }
}

// ==========================================
// 3. MATCHING & TRADE LOOP ENGINE
// ==========================================

export class MatchingEngine {
  private static normalize(skill: string): string {
    return skill.trim().toLowerCase();
  }

  /**
   * Calculates candidate mentor score with bottleneck load-distribution penalty
   */
  private static calculateMentorScore(mentor: UserProfile): number {
    const ratingWeight = (mentor.rating / 5) * 40; // Max 40 pts
    const feedbackWeight = (mentor.feedbackScore / 100) * 30; // Max 30 pts
    const availabilityWeight = Math.min(mentor.availabilityHoursPerWeek / 10, 1) * 20; // Max 20 pts

    // Load distribution penalty: deduct up to 20 pts if mentor has too many concurrent trades
    const bottleneckPenalty = Math.min(mentor.activeTradeCount * 4, 20);

    return Math.max(0, ratingWeight + feedbackWeight + availabilityWeight - bottleneckPenalty + 10);
  }

  /**
   * Returns top 3 match recommendations: tries 1:1 first, then 3-way trade loops
   */
  static findMatches(targetUser: UserProfile, candidates: UserProfile[]): MatchRecommendation[] {
    const pool = candidates.filter((u) => u.id !== targetUser.id);
    const recommendations: MatchRecommendation[] = [];

    // Helper: does user offer a skill matching target's desired skill?
    const hasSkillMatch = (offeredList: string[], desiredList: string[]): string | null => {
      const desiredSet = new Set(desiredList.map(MatchingEngine.normalize));
      for (const skill of offeredList) {
        if (desiredSet.has(MatchingEngine.normalize(skill))) return skill;
      }
      return null;
    };

    // ----------------------------------------
    // Step 1: Direct 1-to-1 Match Search
    // ----------------------------------------
    for (const partner of pool) {
      const targetGets = hasSkillMatch(partner.skillsOffered, targetUser.skillsDesired);
      const partnerGets = hasSkillMatch(targetUser.skillsOffered, partner.skillsDesired);

      if (targetGets && partnerGets) {
        const mentorScore = this.calculateMentorScore(partner);
        const compScore = Math.min(100, Math.round(mentorScore));

        recommendations.push({
          matchType: "DIRECT_1_TO_1",
          compatibilityScore: compScore,
          explanation: `Direct 1:1 trade: You learn ${targetGets} from ${partner.name} while teaching them ${partnerGets}.`,
          tradeChain: [
            { fromUser: targetUser.id, toUser: partner.id, skill: partnerGets },
            { fromUser: partner.id, toUser: targetUser.id, skill: targetGets },
          ],
        });
      }
    }

    // ----------------------------------------
    // Step 2: 3-Way Loop Matching (A -> B -> C -> A)
    // ----------------------------------------
    if (recommendations.length < 3) {
      for (const userB of pool) {
        const skillAToB = hasSkillMatch(targetUser.skillsOffered, userB.skillsDesired);
        if (!skillAToB) continue;

        for (const userC of pool) {
          if (userC.id === userB.id) continue;

          const skillBToC = hasSkillMatch(userB.skillsOffered, userC.skillsDesired);
          const skillCToA = hasSkillMatch(userC.skillsOffered, targetUser.skillsDesired);

          if (skillBToC && skillCToA) {
            const avgMentorScore = (this.calculateMentorScore(userB) + this.calculateMentorScore(userC)) / 2;
            const compScore = Math.min(95, Math.round(avgMentorScore * 0.95)); // Slight penalty for 3-party coordination

            recommendations.push({
              matchType: "LOOP_3_WAY",
              compatibilityScore: compScore,
              explanation: `3-Way trade loop: You teach ${skillAToB} to ${userB.name}, who teaches ${skillBToC} to ${userC.name}, who teaches ${skillCToA} back to you.`,
              tradeChain: [
                { fromUser: targetUser.id, toUser: userB.id, skill: skillAToB },
                { fromUser: userB.id, toUser: userC.id, skill: skillBToC },
                { fromUser: userC.id, toUser: targetUser.id, skill: skillCToA },
              ],
            });
          }
        }
      }
    }

    // Sort by compatibility score descending and return top 3
    return recommendations
      .sort((a, b) => b.compatibilityScore - a.compatibilityScore)
      .slice(0, 3);
  }
}

// ==========================================
// 4. POST-SESSION AI SUMMARY
// ==========================================

export class SessionSummaryService {
  /**
   * Builds the structured system prompt and schema for an LLM to generate
   * actionable takeaways, homework, and follow-ups.
   */
  static buildPrompt(rawNotesOrTranscript: string): { systemPrompt: string; userMessage: string } {
    const systemPrompt = `You are the SkillSwap Learning Quality Agent.
Analyze the provided learning session notes or transcript.
Output ONLY valid JSON matching this schema:
{
  "keyTakeaways": ["3-4 concise points"],
  "actionableHomework": ["1-3 specific practice tasks for the learner"],
  "recommendedFollowUps": ["1-3 topics for the next session"]
}`;

    const userMessage = `Session Transcript / Notes:\n"""\n${rawNotesOrTranscript.trim()}\n"""`;

    return { systemPrompt, userMessage };
  }

  /**
   * Example parser to validate LLM response against expected JSON schema
   */
  static parseLLMOutput(rawJson: string): PostSessionSummary {
    const schema = z.object({
      keyTakeaways: z.array(z.string()).min(1).max(4),
      actionableHomework: z.array(z.string()).min(1),
      recommendedFollowUps: z.array(z.string()).min(1),
    });

    return schema.parse(JSON.parse(rawJson));
  }
}

// ==========================================
// 5. ESCALATION & SUPPORT ROUTING
// ==========================================

export class EscalationService {
  private static SUPPORT_EMAIL = "support@skillswap.com";

  static routeTicket(
    userId: string,
    issueType: EscalationTicket["issueType"],
    description: string,
    metadata: Record<string, unknown> = {}
  ): EscalationTicket {
    const ticket: EscalationTicket = {
      ticketId: `TICK-${Date.now().toString(36).toUpperCase()}`,
      userId,
      issueType,
      description,
      metadata,
      routedTo: this.SUPPORT_EMAIL,
      status: "ROUTED",
      createdAt: new Date().toISOString(),
    };

    console.warn(`[ESCALATION] Routed to ${ticket.routedTo}:`, JSON.stringify(ticket, null, 2));
    return ticket;
  }
}

// ==========================================
// EXAMPLE RUNTIME USAGE
// ==========================================

// Sample database
const sampleUsers: UserProfile[] = [
  {
    id: "usr_alex",
    name: "Alex",
    email: "alex@example.com",
    deviceHash: "dev_hash_111",
    bio: "Senior React engineer looking to master backend Go.",
    skillsOffered: ["React", "TypeScript"],
    skillsDesired: ["Go"],
    rating: 4.9,
    feedbackScore: 96,
    activeTradeCount: 1,
    availabilityHoursPerWeek: 5,
  },
  {
    id: "usr_blake",
    name: "Blake",
    email: "blake@example.com",
    deviceHash: "dev_hash_222",
    bio: "Go developer wanting to learn UI design with Figma.",
    skillsOffered: ["Go"],
    skillsDesired: ["Figma"],
    rating: 4.8,
    feedbackScore: 92,
    activeTradeCount: 2,
    availabilityHoursPerWeek: 4,
  },
  {
    id: "usr_casey",
    name: "Casey",
    email: "casey@example.com",
    deviceHash: "dev_hash_333",
    bio: "Product designer proficient in Figma, eager to learn React fundamentals.",
    skillsOffered: ["Figma"],
    skillsDesired: ["React"],
    rating: 4.7,
    feedbackScore: 90,
    activeTradeCount: 0,
    availabilityHoursPerWeek: 6,
  },
];

// 1. Validation test (Same skill offered and desired)
const invalidProfile: UserProfile = {
  id: "usr_dan",
  name: "Dan",
  email: "dan@example.com",
  deviceHash: "dev_hash_444",
  bio: "Learning coder.",
  skillsOffered: ["Python"],
  skillsDesired: ["Python"],
  rating: 5.0,
  feedbackScore: 100,
  activeTradeCount: 0,
  availabilityHoursPerWeek: 3,
};

const validation = ProfileIntegrityService.validateProfile(invalidProfile, sampleUsers);
console.log("Validation Result:", JSON.stringify(validation, null, 2));

// 2. Matching Engine test (Alex teaches React, wants Go; Blake teaches Go, wants Figma; Casey teaches Figma, wants React)
const matches = MatchingEngine.findMatches(sampleUsers[0], sampleUsers);
console.log("Match Recommendations for Alex:", JSON.stringify(matches, null, 2));
