function cardOffsets(track: HTMLElement): number[] {
  const cards = Array.from(track.children) as HTMLElement[];
  if (cards.length === 0) return [];

  const maxOffset = track.scrollWidth - track.clientWidth;
  const start = cards[0].offsetLeft;

  return cards.map((card) => {
    const centered = getComputedStyle(card).scrollSnapAlign === "center";
    const offset = centered
      ? card.offsetLeft + (card.offsetWidth - track.clientWidth) / 2
      : card.offsetLeft - start;

    return Math.min(maxOffset, Math.max(0, offset));
  });
}

export function scrollSecurityCards(track: HTMLElement, direction: -1 | 1): void {
  const offsets = cardOffsets(track);
  const left =
    direction === 1
      ? offsets.find((offset) => offset > track.scrollLeft + 3)
      : offsets.findLast((offset) => offset < track.scrollLeft - 3);

  if (left !== undefined) {
    track.scrollTo({ left });
  }
}
