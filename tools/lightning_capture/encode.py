"""Encode untouched GPU PNG frames as normal-speed GIFs; no drawn simulation."""
import sys
from pathlib import Path
from PIL import Image

folder = Path(sys.argv[1])
for name in ('anvil1', 'anvil2', 'anvil3', 'forked1', 'forked2'):
    paths = sorted(folder.glob(name + '_*.png'))
    if not paths:
        continue
    frames = [Image.open(p).convert('RGB') for p in paths]
    # Shared palette preserves fine lightning against the dark cloud deck.
    sample = Image.new('RGB', (960, 540 * 4))
    for i, index in enumerate((0, len(frames)//3, len(frames)//2, len(frames)*2//3)):
        sample.paste(frames[index], (0, 540*i))
    palette = sample.quantize(colors=256)
    indexed = [f.quantize(palette=palette, dither=Image.NONE) for f in frames]
    # GIF delays use 10-ms ticks: exactly 100 ms per three 30-fps frames.
    durations = [30, 30, 40] * (len(frames)//3) + [30, 30][:len(frames)%3]
    indexed[0].save(folder/(name+'.gif'), save_all=True, append_images=indexed[1:],
                    duration=durations, loop=0, disposal=2, optimize=False)
    sheet = Image.new('RGB', (960*2, 540*2))
    for i, index in enumerate((15, 25, 40, min(55, len(frames)-1))):
        sheet.paste(frames[index], ((i%2)*960, (i//2)*540))
    sheet.save(folder/(name+'-contact.jpg'), quality=90)
    print(name, len(frames), (folder/(name+'.gif')).stat().st_size, flush=True)
