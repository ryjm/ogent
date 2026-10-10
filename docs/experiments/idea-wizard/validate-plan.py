#!/usr/bin/env python3
"""Check the Idea Wizard export; --publication checks the original plan snapshot."""

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def validate(publication=False):
    evidence_dir = Path(__file__).resolve().parent
    project = evidence_dir.parents[2]
    candidates = json.loads((evidence_dir / 'candidates.json').read_text())
    mapping = json.loads((evidence_dir / 'beads.json').read_text())
    rows = [json.loads(line) for line in (project / '.beads/issues.jsonl').read_text().splitlines() if line.strip()]
    issues = {row['id']: row for row in rows}
    assert len(rows) == len(issues), 'Duplicate issue IDs'
    selected = [idea for idea in candidates['ideas'] if idea['selected']]
    assert len(candidates['ideas']) == 30 and len(selected) == 15
    assert len(mapping['features']) == 15 and len(mapping['tasks']) == 45
    future_ids = {mapping['root'], *mapping['features'].values(), *mapping['tasks'].values()}
    assert len(future_ids) == 61 and future_ids <= issues.keys()
    assert [review['pass'] for review in mapping['reviews']] == [1, 2, 3, 4, 5]
    assert all(review['reviewed_future_records'] == 61 for review in mapping['reviews'])
    for idea in candidates['ideas']:
        assert len(idea['scores']) == 10 and 2 <= min(idea['scores']) <= max(idea['scores']) <= 5
        assert sum(idea['scores']) / 10 >= 3
        calculated = round(sum(a*b for a, b in zip(idea['scores'], candidates['weights'])) / sum(candidates['weights']), 2)
        assert calculated == idea['weighted_score']
    assert max(idea['weighted_score'] for idea in candidates['ideas'] if not idea['selected']) < min(idea['weighted_score'] for idea in selected)
    parents = {}
    adjacency = {}
    for ident in future_ids:
        row = issues[ident]
        assert len(row['description']) > 3000 and 'Governing contract' in row['description'], ident
        if publication:
            assert row['status'] == 'open', f'Future implementation already started: {ident}'
        dependencies = row.get('dependencies', [])
        parents[ident] = [dep['depends_on_id'] for dep in dependencies if dep['type'] == 'parent-child']
        adjacency[ident] = [dep['depends_on_id'] for dep in dependencies if dep['type'] == 'blocks']
        assert all(dep in future_ids for dep in adjacency[ident]), ident
    for idea in selected:
        key = idea['key']
        feature = mapping['features'][key]
        assert parents[feature] == [mapping['root']]
        assert len(idea['scores']) == 10 and min(idea['scores']) >= 2
        calculated = round(sum(a*b for a, b in zip(idea['scores'], candidates['weights'])) / sum(candidates['weights']), 2)
        assert calculated == idea['weighted_score']
        assert all((project / source).exists() for source in idea['modules'])
        core, surface, verify = [mapping['tasks'][key + '.' + stage] for stage in ['core', 'surface', 'verify']]
        for child in [core, surface, verify]:
            assert parents[child] == [feature]
            assert issues[child].get('acceptance_criteria'), child
            assert 'No provider login' in issues[child]['description']
        assert core in adjacency[surface]
        assert {core, surface} <= set(adjacency[verify])
        assert 'Refinement 1' in issues[core].get('notes', '')
        assert 'Refinement 3' in issues[verify].get('notes', '')
        assert 'Refinement 4' in issues[feature].get('notes', '')
    visiting, visited = set(), set()

    def visit(ident):
        assert ident not in visiting, f'Dependency cycle at {ident}'
        if ident in visited:
            return
        visiting.add(ident)
        for dependency in adjacency[ident]:
            visit(dependency)
        visiting.remove(ident)
        visited.add(ident)

    for ident in future_ids:
        visit(ident)
    roots = sorted(ident for ident in future_ids if issues[ident]['issue_type'] == 'task' and not adjacency[ident])
    ready = sorted(ident for ident in future_ids if issues[ident]['issue_type'] == 'task'
                   and issues[ident]['status'] == 'open'
                   and all(issues[dependency]['status'] == 'closed' for dependency in adjacency[ident]))
    for key in ['I01.core', 'I02.core', 'I03.core', 'I05.core']:
        assert mapping['tasks'][key] in roots
    result = dict(validated_at=datetime.now(timezone.utc).isoformat(), publication_snapshot=publication,
                  baseline=mapping['baseline'], candidates=30, selected_ideas=15, future_beads=61,
                  blocking_edges=sum(map(len, adjacency.values())), dependency_cycles=0,
                  independent_core_tasks=roots, ready_tasks=ready, refinement_passes=len(mapping['reviews']))
    if publication:
        assert issues[mapping['planning']]['status'] == 'closed'
        old_export = subprocess.run(['git', 'show', mapping['baseline'] + ':.beads/issues.jsonl'], cwd=project,
                                    capture_output=True, text=True, check=True).stdout
        historical = [json.loads(line) for line in old_export.splitlines() if line.strip()]
        assert len(historical) == 196
        assert all(issues[row['id']] == row for row in historical), 'Historical bead changed'
        assert set(issues) - {row['id'] for row in historical} == future_ids | {mapping['planning']}
        code_diff = subprocess.run(['git', 'diff', mapping['baseline'], '--', 'lisp', 'test', 'makem.sh', 'Makefile', '.github'],
                                   cwd=project, capture_output=True, text=True, check=True).stdout
        assert not code_diff, 'Production/test/build source changed during planning'
        result.update(historical_beads_unchanged=196, planning_task_closed=True, future_implementation_open=True,
                      production_test_build_source_unchanged=True)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publication', action='store_true', help='Require the unstarted publication snapshot and unchanged historical/source records.')
    args = parser.parse_args()
    print(json.dumps(validate(args.publication), indent=2))
