"""Plot observed movement and coverage, never inferred command success."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def plot(folder):
    results = json.loads((folder/'summary.json').read_text(encoding='utf-8'))
    figure, axes = plt.subplots(1, len(results), figsize=(5*len(results), 5), squeeze=False)
    curves, curve_ax = plt.subplots(figsize=(9, 4))
    for report, ax in zip(results, axes[0]):
        number = report['round']
        rows = [json.loads(line) for line in (folder/str(number)/'events.jsonl').read_text(encoding='utf-8').splitlines()]
        if not rows:
            continue
        curve_ax.plot([(row['tick']-rows[0]['tick'])/60 for row in rows],
                      [row['coverage']*100 for row in rows], label='Round '+str(number))
        units = {unit['name'] for row in rows for unit in row['units'] if unit.get('movement')}
        for name in sorted(units):
            positions = [unit['pos'] for row in rows for unit in row['units'] if unit['name']==name]
            ax.plot([p[0] for p in positions], [p[2] for p in positions], label=name)
            ax.scatter(positions[-1][0], positions[-1][2], s=25)
        remaining = report.get('unobserved_cells', [])
        if remaining:
            ax.scatter([p[0]+.5 for p in remaining], [p[1]+.5 for p in remaining],
                       marker='s', s=8, color='#dddddd', zorder=0, label='Unobserved')
        ax.set(xlim=(0,report['bounds'][0]), ylim=(0,report['bounds'][1]), aspect='equal',
               xlabel='x (m)', ylabel='z (m)', title='Round %d: %.2f%%' % (number,report['final_coverage']*100))
        ax.legend(fontsize=7)
    figure.tight_layout()
    figure.savefig(folder/'paths.png', dpi=160)
    curve_ax.set(xlabel='Game seconds (60 physics ticks/s)', ylabel='Sampled coverage (%)', ylim=(0,100),
                 title='Real model exploration; no computer AI opponents')
    curve_ax.legend()
    curve_ax.grid(alpha=.2)
    curves.tight_layout()
    curves.savefig(folder/'coverage.png', dpi=160)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('folder', type=Path)
    plot(parser.parse_args().folder)
