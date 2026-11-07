#!/usr/bin/env python3
# Equal-budget constructed profiles, timing resolution, and isolated price tests.
import argparse
import copy
import json
import hashlib
from pathlib import Path
import numpy as np
import simulator as sim

NAMES = ("regen_generalist", "crit_specialist", "spell_specialist", "poison_specialist", "hybrid_mage", "multi_axis_cap_chaser")
CONTEXTS = ((1,0,0),(1,20,10),(15,10,5),(30,20,10),(30,60,20),
            (45,40,20),(60,0,20),(60,20,10),(60,60,20),(60,100,20))


def build_from_profile(p, n, config):
    keys = list(config["affixes"])
    stats = np.zeros((n,len(keys)))
    for key,value in p["gear_stats"].items():
        stats[:,keys.index(sim.canonical_stat_name(key))] = value
    return {"stats":stats,"primary":np.tile(list(p["primary_points"].values()),(n,1)).astype(np.int16),
            "talents":np.tile(list(p["talent_points"].values()),(n,1)).astype(np.int16),
            "archetype":np.full(n,sim.ARCHETYPES.index(p["archetype"])),"shield":np.full(n,p["shield"]),
            "choices":np.tile([keys.index(sim.canonical_stat_name(k)) for k in p["gear_affixes"]],(n,1)),
            "keys":keys,"budget":p["gear_budget"],"model":p["cost_model"],
            "level":p["level"],"talent_budget":p["talent_budget"]}


def constructed_profile(name,budget,model,rules,config,level=60,talent_budget=10):
    points = rules["creation_points"]+rules["points_per_level"]*(level-1)
    if name == "regen_generalist":
        a,primary,talents,shield=1,[0,points//2,0,points-points//2],[talent_budget,0,0],True
        gear=["armor"]*3+["evasion"]*3+["resistance"]*2+["health_regen"]*4+["health"]*4+["attack_power"]*2+["block"]*2
    elif name == "crit_specialist":
        a,primary,talents,shield=0,[points,0,0,0],[0,talent_budget,0],False
        gear=["health"]*8+["critical_chance"]*4+["critical_multiplier"]*4+["penetration"]*2+["attack_power"]*2
    elif name == "spell_specialist":
        a,primary,talents,shield=2,[0,0,points,0],[0,talent_budget,0],False
        gear=["mana"]*6+["health"]*2+["spell_power"]*5+["general_damage"]*3+["spell_power"]*4
    elif name == "poison_specialist":
        a,primary,talents,shield=3,[0,points,0,0],[0,talent_budget,0],False
        gear=["health"]*4+["evasion"]*4+["attack_power"]*4+["dot_damage"]*4+["attack_power"]*4
    elif name == "hybrid_mage":
        a,primary,talents,shield=2,[0,0,points//2,points-points//2],[talent_budget//2,talent_budget-talent_budget//2,0],True
        gear=["armor"]*3+["evasion"]*3+["resistance"]*2+["spell_power"]*4+["health_regen"]*2+["critical_chance"]*2+["spell_power"]*2+["block"]*2
    elif name == "multi_axis_cap_chaser":
        dexterity=points*25//128
        a,primary,talents,shield=2,[0,dexterity,points-dexterity,0],[talent_budget,0,0],True
        gear=["armor"]*4+["evasion"]*2+["resistance"]*2+["critical_chance"]*4+["critical_multiplier"]*4+["spell_power"]*2+["block","evasion"]
    else:
        raise ValueError(name)
    keys=list(config["affixes"])
    stats=np.zeros((1,len(keys)))
    slot=0
    for group in config["slot_groups"].values():
        for _ in range(group["count"]):
            key=gear[slot]
            if key not in group["allowed"]:
                raise ValueError(f"Illegal {name} affix {key} in slot {slot}")
            stats[0,keys.index(key)]+=budget/config["affix_slots"]*config["affixes"][key]/config["cost_models"][model].get(key,1)
            slot+=1
    b={"stats":stats,"primary":np.array([primary]),"talents":np.array([talents]),"archetype":np.array([a]),
       "shield":np.array([shield]),"choices":np.array([[keys.index(k) for k in gear]]),"keys":keys,
       "budget":budget,"model":model,"level":level,"talent_budget":talent_budget}
    assert b["primary"].sum()==points and b["talents"].sum()==talent_budget
    d=sim.derive(b,rules,config)
    p=sim.payloads(b,d,rules,config)
    result=sim.profile(b,d,sim.metrics(b,d,p,rules,config),0)
    result.pop("fraction_of_individual_axis_best")
    result["name"]=name
    return result


def trial(p,n,step,rules,config,seed):
    config=copy.deepcopy(config)
    config["encounter"]["step_seconds"]=step
    b=build_from_profile(p,n,config)
    d=sim.derive(b,rules,config)
    payload=sim.payloads(b,d,rules,config)
    result=sim.encounters(b,d,payload,np.random.default_rng(seed),rules,config)
    pressures={}
    for i,scenario in enumerate(config["encounter"]["pressures"]):
        mask=result["pressure"]==i
        pressures[scenario["name"]]={"trials":int(mask.sum()),"win_fraction":float(result["won"][mask].mean()),
                                      "survival_fraction":float(result["survived"][mask].mean())}
    return {"trials":n,"step_seconds":step,"win_fraction":float(result["won"].mean()),
            "survival_fraction":float(result["survived"].mean()),"mean_elapsed":float(result["elapsed"].mean()),
            "minimum_enemy_level":int(result["enemy_level"].min()),"maximum_enemy_level":int(result["enemy_level"].max()),
            "pressures":pressures}


def timing_row(p,name,n,rules,config):
    coarse=trial(p,n,.5,rules,config,8675309)
    fine=trial(p,n,.1,rules,config,8675309)
    return {"name":name,"model":p["cost_model"],"level":p["level"],"gear":p["gear_budget"],
            "coarse":coarse,"fine":fine,"absolute_win_fraction_difference":abs(coarse["win_fraction"]-fine["win_fraction"])}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--output",type=Path,default=sim.HERE/"results")
    parser.add_argument("--profile-trials",type=int,default=512)
    parser.add_argument("--timing-trials",type=int,default=2048)
    args=parser.parse_args()
    rules,config=sim.read_json(sim.DEFAULT_RULES),sim.read_json(sim.HERE/"scenarios.json")
    sim.require_legacy_report_schema(rules)
    profiles=[]
    for model in config["cost_models"]:
        for level,gear,talents in CONTEXTS:
            for name in NAMES:
                p=constructed_profile(name,gear,model,rules,config,level,talents)
                p["encounter_audit"]=trial(p,args.profile_trials,.5,rules,config,20261105)
                profiles.append(p)
    timing=[]
    for p in profiles:
        if ((p["level"],p["gear_budget"],p["talent_budget"]) in ((30,20,10),(60,60,20)) and p["name"]!="crit_specialist") or (p["level"]==60 and p["gear_budget"]==100 and p["talent_budget"]==20 and p["name"]=="multi_axis_cap_chaser"):
            timing.append(timing_row(p,p["name"],args.timing_trials,rules,config))
    sampled=sim.read_json(args.output/"top_builds.json")
    for model in config["cost_models"]:
        for context in ((1,10,5),(30,20,10),(60,20,10),(60,100,20)):
            choices=[p for p in sampled if p["cost_model"]==model and (p["level"],p["gear_budget"],p["talent_budget"])==context]
            selected={"sampled_offense_best":max(choices,key=lambda p:p["objectives"]["damage_per_second"]),
                      "sampled_balanced_best":max(choices,key=lambda p:np.prod(list(p["fraction_of_individual_axis_best"].values())))}
            timing.extend(timing_row(p,name,args.timing_trials,rules,config) for name,p in selected.items())
    sensitivity=[]
    factors={"baseline":{},"regen_price":{"health_regen":8},"block_price":{"block":2},
             "all_resistance_price":{"resistance":6},"critical_price":{"critical_multiplier":1.5},
             "armor_price":{"armor":1.5},"evasion_price":{"evasion":1.5}}
    for factor,costs in factors.items():
        changed=copy.deepcopy(config)
        changed["cost_models"]["one_factor"]=costs
        for level,gear,talents in ((1,20,10),(30,20,10),(60,60,20)):
            for name in ("regen_generalist","crit_specialist","hybrid_mage","poison_specialist"):
                p=constructed_profile(name,gear,"one_factor",rules,changed,level,talents)
                sensitivity.append({"factor":factor,"level":level,"gear":gear,"talents":talents,"name":name,
                                    "objectives":p["objectives"],"encounters":trial(p,args.profile_trials,.5,rules,changed,314159)})
    fast=[]
    for variant in ("saved_reference","fast_normalized","fast_unnormalized"):
        changed=copy.deepcopy(config)
        if variant!="saved_reference":
            changed["reference_abilities"]["melee"]["interval"]*=.5
            changed["reference_abilities"]["melee"]["minimum_action_duration"]*=.5
        if variant=="fast_normalized":
            for key in ("base_damage","power_coefficient","stamina_cost"):
                changed["reference_abilities"]["melee"][key]*=.5
        p=constructed_profile("crit_specialist",60,"initial",rules,changed,60,20)
        fast.append({"variant":variant,"objectives":p["objectives"],"encounters":trial(p,args.profile_trials,.1,rules,changed,314159)})
    report={"description":"Constructed funded profiles, isolated price sensitivities, and timing resolution. Different resolutions also change RNG event streams; observed timing differences include sampling noise.",
            "auditor_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "constructed_profile_count":len(profiles),"constructed_encounter_trials":len(profiles)*args.profile_trials,
            "timing_encounter_trials":len(timing)*args.timing_trials*2,"one_factor_encounter_trials":len(sensitivity)*args.profile_trials,
            "fast_weapon_encounter_trials":len(fast)*args.profile_trials,
            "profiles":profiles,"timing_sensitivity":timing,"one_factor_sensitivity":sensitivity,"fast_weapon_sensitivity":fast}
    (args.output/"adversarial_audit.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    lines=["# Constructed builds and sensitivity","",report["description"],"",
           f"{report['constructed_encounter_trials']:,} constructed encounters; {report['timing_encounter_trials']:,} timing trials; {report['one_factor_encounter_trials']:,} one-factor price trials; {report['fast_weapon_encounter_trials']:,} weapon-rate trials. Separate from the main experiment.","",
           "| Model | Level | Gear | Talents | Profile | DPS | Physical EHP | Elemental EHP | DoT EHP | Regen/s | Win rate |",
           "|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|"]
    for p in profiles:
        o,d,a=p["objectives"],p["derived"],p["encounter_audit"]
        lines.append(f"| {p['cost_model']} | {p['level']} | {p['gear_budget']} | {p['talent_budget']} | {p['name']} | {o['damage_per_second']:.1f} | {o['physical_ehp']:.0f} | {o['elemental_ehp']:.0f} | {o['periodic_ehp']:.0f} | {d['health_regen']:.2f} | {a['win_fraction']:.1%} |")
    lines+=["","## Timing","","| Model | Level | Gear | Profile | 0.5s win rate | 0.1s win rate | Difference |","|---|---:|---:|---|---:|---:|---:|"]
    for r in timing:
        lines.append(f"| {r['model']} | {r['level']} | {r['gear']} | {r['name']} | {r['coarse']['win_fraction']:.2%} | {r['fine']['win_fraction']:.2%} | {r['absolute_win_fraction_difference']:.2%} |")
    lines+=["","## Price and weapon-rate checks","","The JSON contains isolated price results. The fast-normalized variant halves per-hit base, Power coefficient and Stamina cost while doubling the attack rate. The fast-unnormalized variant deliberately omits that compensation. These variants do not modify saved abilities.",
            "Relative broad-build scores at weak zero budgets are not proof of excessive absolute power. No sampled study proves absence of exploits."]
    (args.output/"adversarial_audit.md").write_text("\n".join(lines)+"\n",encoding="utf-8")
    main_report=sim.read_json(args.output/"report.json")
    overview=["# Budget experiment findings","",
              f"{main_report['build_evaluations']:,} sampled build evaluations and {main_report['stochastic_encounter_trials']:,} encounter trajectories across {main_report['independent_budget_contexts']} budget contexts and {main_report['comparison_cells']} model/seed cells. Sampling is with replacement; per-cell exact distinct-profile counts are in report.json, not a claim of ten million unique builds.","",
              "## Selected equal-budget contexts","",
              "Counts below combine the two independent seeds only within the same level/gear/talent/price context. Relative near-best builds at a low-budget baseline may simply reflect little room for specialization.","",
              "| Model | Level | Gear | Talents | Evaluations | All4 axes top decile | All4 axes>=80% independent best | Steady Physical pressure outhealed |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for context in ((1,0,0),(1,20,10),(30,20,10),(60,20,10),(60,60,20),(60,100,20)):
        for model in config["cost_models"]:
            groups=[g for g in main_report["groups"] if g["model"]==model and (g["level"],g["budget"],g["talent_budget"])==context]
            count=sum(g["build_evaluations"] for g in groups)
            broad=sum(g["top_decile_all_four_axes_count"] for g in groups)
            near=sum(g["within_80_percent_of_all_four_axis_bests_count"] for g in groups)
            regen=sum(g["steady_physical_pressure_outhealed_fraction"]*g["build_evaluations"] for g in groups)/count
            overview.append(f"| {model} | {context[0]} | {context[1]} | {context[2]} | {count:,} | {broad} | {near} | {regen:.2%} |")
    overview += ["","## Constructed corner case","",
                 "Random archive absence does not prove a combination impossible. The targeted multi-axis cap chaser below spends its full gear and talent budgets. Initial pricing allows every defensive cap plus substantial critical spell offense; this is a content-budget risk, not evidence that an arbitrary low-investment character can do everything.","",
                 "| Price model | Gear | Talents | Reference DPS | Physical EHP | Elemental EHP | Periodic EHP | Crit chance | Crit multiplier | Sampled win rate |",
                 "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for p in profiles:
        if p["name"]=="multi_axis_cap_chaser" and p["level"]==60 and p["gear_budget"]==100:
            o,d=p["objectives"],p["derived"]
            overview.append(f"| {p['cost_model']} | {p['gear_budget']} | {p['talent_budget']} | {o['damage_per_second']:.2f} | {o['physical_ehp']:.0f} | {o['elemental_ehp']:.0f} | {o['periodic_ehp']:.0f} | {d['critical_chance_fraction']:.0%} | {d['critical_multiplier_value']:.2f} | {p['encounter_audit']['win_fraction']:.2%} |")
    overview += ["","## Sensitivity and coverage limits","",
                 f"Supplemental trials: {report['constructed_encounter_trials']:,} constructed encounters, {report['timing_encounter_trials']:,} timing trials, {report['one_factor_encounter_trials']:,} isolated-price trials, {report['fast_weapon_encounter_trials']:,} weapon-rate trials.",
                 f"Maximum observed difference between0.5s and0.1s timing is {max(r['absolute_win_fraction_difference'] for r in timing):.2%} in win rate; different RNG streams also contribute sampling noise.",
                 "All direct incoming hits are eligible for player dodge and block. Reference targets have no dodge/block, so maintaining Poison stacks against evasive or shielded targets is not validated. Movement, kiting, control, healing choices, aiming, and AI are omitted.",
                 "Uncapped regeneration and multiplying defenses can sustain finite pressure. The reviewed prices reduce some risks without changing game caps; the study does not certify finished balance."]
    (args.output/"findings.md").write_text("\n".join(overview)+"\n",encoding="utf-8")
    print(json.dumps({k:v for k,v in report.items() if not isinstance(v,list)},indent=2))


if __name__=="__main__":
    main()
