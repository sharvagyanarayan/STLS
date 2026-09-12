const modal = document.getElementById("signin");
const closeBtn = document.querySelector(".close");
const signInLinks = document.querySelectorAll('a[href="#signin"]');
const menuBtn = document.querySelector(".menu-btn");
const navLinks = document.querySelector(".nav-links");

function openModal(event) {
  event.preventDefault();
  modal.classList.add("open");
  modal.setAttribute("aria-hidden", "false");
}

function closeModal() {
  modal.classList.remove("open");
  modal.setAttribute("aria-hidden", "true");
}

signInLinks.forEach(link => link.addEventListener("click", openModal));
closeBtn.addEventListener("click", closeModal);

modal.addEventListener("click", event => {
  if (event.target === modal) closeModal();
});

document.addEventListener("keydown", event => {
  if (event.key === "Escape") closeModal();
});

menuBtn.addEventListener("click", () => {
  navLinks.classList.toggle("mobile-open");
});

document.querySelectorAll(".nav-links a").forEach(link => {
  link.addEventListener("click", () => navLinks.classList.remove("mobile-open"));
});