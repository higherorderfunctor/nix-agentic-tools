# The file and directory recipes claim the same nested leaf.
# The loader must report both sources before calling the file recipe.
_: throw "package ownership must fail before evaluating the file recipe"
