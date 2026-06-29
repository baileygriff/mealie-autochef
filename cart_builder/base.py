"""
base.py — GroceryProvider ABC, shared data types, and exception hierarchy.

All cart_builder code that isn't Food Lion-specific lives here.
To add a new grocery store:
  1. Create cart_builder/providers/your_store.py
  2. Subclass GroceryProvider and implement the 5 abstract methods
  3. Register it in cart.py's PROVIDER_MAP
  See cart_builder/README.md for a full walkthrough.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class CartItem:
    search_term: str
    default_qty: int
    pack_unit: Optional[str] = None


@dataclass
class CartSummary:
    total: Optional[float]
    item_count: int
    pickup_slot: Optional[str]
    flagged_items: list
    screenshot_path: Optional[str]
    previous_purchases_stats: Optional[dict]


class SessionExpiredError(Exception):
    """Raised by navigate_to_store() when the saved session is invalid."""

    def __init__(self, reason: str):
        self.reason = reason  # "kasada_challenge" | "login_required"
        super().__init__(reason)


class GroceryProvider(ABC):
    """
    Abstract base for grocery store cart automation providers.

    Each provider is responsible for:
      - Maintaining its own browser/page state internally
      - Implementing the 5 methods below
      - Raising SessionExpiredError from navigate_to_store() if session is bad

    The workflow (CartWorkflow) calls these methods in order and handles the
    JSON output contract with the Ruby side. Providers never write to stdout.
    """

    @abstractmethod
    def navigate_to_store(self, store_name: str) -> None:
        """
        Open the store and confirm the session is valid.
        Raises SessionExpiredError if Kasada challenge or login redirect detected.
        """

    @abstractmethod
    def clear_cart(self) -> int:
        """Remove all items currently in the cart. Returns the count removed."""

    @abstractmethod
    def select_slot(self, pickup_window_pref: str) -> Optional[str]:
        """
        Configure the pickup or delivery slot.
        Returns the confirmed slot string (e.g. 'Thu 5:00-6:00 PM') or None
        if no matching slot was found or the store doesn't use slot selection.
        """

    @abstractmethod
    def add_items(self, items: list) -> tuple:
        """
        Add items to the cart. Providers may use any strategy (e.g. Previous
        Purchases first, then search-based fallback).

        Returns:
          added:   list[CartItem] successfully added to the cart
          flagged: list[str] search_term strings for items that couldn't be added
        """

    @abstractmethod
    def capture_summary(self, run_key: str) -> CartSummary:
        """
        Capture the final cart state: total, screenshot, slot, flagged items.
        Providers that tracked previous_purchases_stats during add_items()
        should surface them here.
        """
