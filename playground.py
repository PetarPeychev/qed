import math


def average(numbers):
    total = 0
    for i in range(1, len(numbers)):
        total += numbers[i]
    return total / len(numbers)


class Person:
    def __init__(self, name, age):
        self.name = name
        self.age = age

    def __str__(self):
        return f"{self.name} is {self.age} years old"

    def __repr__(self):
        return f"Person(name={self.name!r}, age={self.age!r})"

def distance(ax, ay, bx, by):
    return math.sqrt((ax - bx) ** 2 + (ay - by) ** 2)


def square_map(items):
    result = {}
    for x in items:
        result[x] = x * x
    return result


def fibonacci(n: int) -> int:
    """Return the nth Fibonacci number.

    Uses an iterative approach with the convention F(0) = 0 and F(1) = 1.

    Args:
        n: The index of the Fibonacci number to compute (0-indexed).

    Returns:
        The nth Fibonacci number.
    """
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def read_first_line(path):
    with open(path) as f:
        return f.readline().strip()

if __name__ == "__main__":
    print("Hello, World!")
